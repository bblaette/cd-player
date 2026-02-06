import Foundation

enum ContainerStatus: String {
    case running = "running"
    case paused = "paused"
    case exited = "exited"
    case created = "created"
    case other = "other"

    init(from state: String) {
        switch state.lowercased() {
        case "running": self = .running
        case "paused": self = .paused
        case "exited": self = .exited
        case "created": self = .created
        default: self = .other
        }
    }

    var icon: String {
        switch self {
        case .running: return "●"
        case .paused: return "◐"
        case .exited, .created, .other: return "○"
        }
    }
}

struct DockerContainer: Identifiable, Equatable {
    let id: String
    let shortId: String
    let name: String
    let image: String
    let status: ContainerStatus
    let statusText: String
    let ports: String
    let created: String

    /// Approximate seconds from statusText for sorting by duration.
    /// Smaller = more recent = sorts first ascending.
    /// Non-running containers get +1 second so they sort after equally-timed running ones.
    var sortableSeconds: Double {
        let text = statusText.lowercased()
        let bonus: Double = (status != .running) ? 1 : 0
        let pattern = #"(\d+)\s*(second|minute|hour|day|week|month|year)s?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else {
            if text.contains("about a minute") || text.contains("about an hour") {
                return (text.contains("minute") ? 60 : 3600) + bonus
            }
            return Double.greatestFiniteMagnitude
        }
        let num = Double(text[numRange]) ?? 0
        let unit = String(text[unitRange])
        let base: Double
        switch unit {
        case "second": base = num
        case "minute": base = num * 60
        case "hour": base = num * 3600
        case "day": base = num * 86400
        case "week": base = num * 604800
        case "month": base = num * 2592000
        case "year": base = num * 31536000
        default: return Double.greatestFiniteMagnitude
        }
        return base + bonus
    }

    var displayLabel: String {
        // let idPrefix = String(shortId.prefix(5))
        // return "\(name)  (\(idPrefix))"
        return name
    }

    /// Shortened status for table display
    /// "Up About a minute (healthy)" -> "1 minute, healthy"
    /// "Exited (0) 3 weeks ago" -> "(3 weeks ago)"
    var shortStatus: String {
        var text = statusText
        if text.hasPrefix("Up ") {
            text = String(text.dropFirst(3))
            // "About a minute" -> "1 minute", "About an hour" -> "1 hour"
            text = text.replacingOccurrences(of: "About a ", with: "1 ")
            text = text.replacingOccurrences(of: "About an ", with: "1 ")
            // Parenthesized qualifiers: " (healthy)" -> ", healthy"
            if let parenRange = text.range(of: #" \(([^)]+)\)"#, options: .regularExpression) {
                let inner = text[parenRange].dropFirst(2).dropLast(1) // strip " (" and ")"
                text = text[..<parenRange.lowerBound] + ", " + inner
            }
            return text
        }
        if let range = text.range(of: #"^Exited \(\d+\) "#, options: .regularExpression) {
            let remainder = text[range.upperBound...]
            return "(\(remainder))"
        }
        return text
    }

    /// Parse port mappings from the raw docker ports string.
    /// Returns array of shortened port strings like "9243->443"
    static func parsePorts(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        // Docker format: "0.0.0.0:9243->443/tcp, :::9243->443/tcp, 0.0.0.0:5432->5432/tcp"
        // We only want tcp, deduplicate by host->container, strip IPs
        var seen = Set<String>()
        var result: [String] = []
        for part in raw.components(separatedBy: ", ") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("/tcp") else { continue }
            // Strip protocol suffix
            let withoutProto = String(trimmed.dropLast(4))
            // Strip IP prefix: "0.0.0.0:9243->443" or ":::9243->443" -> "9243->443"
            let arrow = withoutProto.components(separatedBy: "->")
            guard arrow.count == 2 else { continue }
            let hostPart = arrow[0]
            let containerPort = arrow[1]
            // Get just the port number from host side (after last colon)
            let hostPort: String
            if let lastColon = hostPart.lastIndex(of: ":") {
                hostPort = String(hostPart[hostPart.index(after: lastColon)...])
            } else {
                hostPort = hostPart
            }
            let short = "\(hostPort)->\(containerPort)"
            if !seen.contains(short) {
                seen.insert(short)
                result.append(short)
            }
        }
        return result
    }

    /// First port for compact display, with ellipsis if more
    var shortPortsDisplay: String {
        let parsed = Self.parsePorts(ports)
        if parsed.isEmpty { return "—" }
        if parsed.count == 1 { return parsed[0] }
        return "\(parsed[0]) ..."
    }

    /// Full ports for expanded display
    var fullPortsDisplay: String {
        let parsed = Self.parsePorts(ports)
        return parsed.isEmpty ? "—" : parsed.joined(separator: ", ")
    }
}

/// Diagnostic state when docker is unavailable
enum DockerUnavailableReason: Equatable {
    case none                    // Docker is available
    case permissionDenied        // Socket exists but permission denied
    case daemonNotRunning        // Socket exists but daemon not running
    case socketNotFound          // Socket path doesn't exist
    case unknown                 // Other error
}

@MainActor
final class DockerManager: ObservableObject {
    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var pinnedContainerIds: [String] = []
    @Published private(set) var isAvailable = false
    /// Why docker is unavailable (for remote user scenarios)
    @Published private(set) var unavailableReason: DockerUnavailableReason = .none

    private var pollTimer: Timer?
    private var fastPollTimer: Timer?
    private let maxPins = 10
    /// Container IDs that were manually unpinned — don't auto-pin these again
    private var manuallyUnpinned: Set<String> = []

    /// The configured user for running docker commands (nil = current user)
    private var configuredUser: String?
    private let currentUser = ProcessInfo.processInfo.userName

    /// Whether docker runs as a different user
    private var isRemoteUser: Bool {
        guard let user = configuredUser else { return false }
        return user != currentUser
    }

    /// Docker socket path for the configured user's colima instance.
    /// We construct the path directly since we can't list another user's home directory on macOS.
    private func dockerSocketPath() -> String? {
        guard let user = configuredUser, isRemoteUser else { return nil }
        return "/Users/\(user)/.colima/default/docker.sock"
    }

    /// Find the docker binary path (avoid shell aliases)
    private nonisolated static let dockerBinary: String = {
        let searchPaths = [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/usr/bin/docker"
        ]
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "docker"  // fallback to PATH lookup
    }()

    /// Extra environment variables for docker commands (DOCKER_HOST for remote user)
    private var dockerEnv: [String: String]? {
        guard let socket = dockerSocketPath() else { return nil }
        return ["DOCKER_HOST": "unix://\(socket)"]
    }

    /// Build a docker command string for Terminal (interactive, exports DOCKER_HOST if needed)
    func dockerTerminalCommand(_ cmd: String) -> String {
        if let socket = dockerSocketPath() {
            return "DOCKER_HOST=unix://\(socket) \(Self.dockerBinary) \(cmd)"
        }
        return "\(Self.dockerBinary) \(cmd)"
    }

    /// Run diagnostics and return a user-friendly message
    func runDiagnostics() -> (title: String, message: String) {
        guard let socket = dockerSocketPath(), let user = configuredUser else {
            return ("No Remote User", "No remote user configured. Use 'Set User' in the menu first.")
        }

        let fm = FileManager.default
        var lines: [String] = []

        lines.append("Socket: \(socket)")
        lines.append("Configured user: \(user)")
        lines.append("Current user: \(currentUser)")
        lines.append("")

        // Check if socket exists
        if !fm.fileExists(atPath: socket) {
            lines.append("Socket does not exist.")
            lines.append("")
            lines.append("The colima daemon may not be running for user '\(user)'.")
            return ("Socket Not Found", lines.joined(separator: "\n"))
        }

        // Get socket permissions
        if let attrs = try? fm.attributesOfItem(atPath: socket) {
            let posix = attrs[.posixPermissions] as? Int ?? 0
            let owner = attrs[.ownerAccountName] as? String ?? "?"
            let group = attrs[.groupOwnerAccountName] as? String ?? "?"
            let perms = String(format: "%o", posix)
            lines.append("Socket permissions: \(perms) (owner: \(owner), group: \(group))")
        }

        // Check directory traversability
        let dirs = [
            "/Users/\(user)",
            "/Users/\(user)/.colima",
            "/Users/\(user)/.colima/default"
        ]
        var dirIssues: [String] = []
        for dir in dirs {
            if !fm.isExecutableFile(atPath: dir) {
                dirIssues.append(dir)
            }
        }
        if !dirIssues.isEmpty {
            lines.append("")
            lines.append("Directories not traversable:")
            for dir in dirIssues {
                lines.append("  \(dir)")
            }
        }

        // Test actual connection
        let env = dockerEnv
        let output = runShellCommand("\(Self.dockerBinary) info 2>&1", extraEnv: env)

        if output.contains("permission denied") {
            lines.append("")
            lines.append("Permission denied when connecting to socket.")
            lines.append("")
            lines.append("Ensure the current user has group read/write access to the socket file, and that parent directories are traversable.")
            return ("Permission Denied", lines.joined(separator: "\n"))
        } else if output.contains("Is the docker daemon running") || output.contains("Cannot connect") {
            lines.append("")
            lines.append("Cannot connect to docker daemon.")
            lines.append("")
            lines.append("The colima daemon may not be running for user '\(user)'.")
            return ("Daemon Not Running", lines.joined(separator: "\n"))
        } else if output.contains("Server:") {
            lines.append("")
            lines.append("Docker is accessible!")
            startFastPolling()
            return ("Docker Accessible", lines.joined(separator: "\n"))
        } else {
            lines.append("")
            lines.append("Unexpected error:")
            lines.append(output.prefix(500).description)
            return ("Error", lines.joined(separator: "\n"))
        }
    }

    private static let configDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cd-player")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let dockerFile: URL = configDir.appendingPathComponent("docker.json")
    // Legacy files for migration
    private static let legacyPinsFile: URL = configDir.appendingPathComponent("pins.json")
    private static let legacyUnpinnedFile: URL = configDir.appendingPathComponent("unpinned.json")

    var pinnedContainers: [DockerContainer] {
        pinnedContainerIds.compactMap { pinId in
            containers.first { $0.id == pinId || $0.name == pinId }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    init() {
        configuredUser = ColimaConfig.getColimaUser()
        loadDockerConfig()
        startPolling()
    }

    /// Update the configured user (called when Set User changes)
    func updateConfiguredUser(_ user: String?) {
        configuredUser = user
        refresh()
    }

    deinit {
        pollTimer?.invalidate()
        fastPollTimer?.invalidate()
    }

    func startPolling() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        Task {
            let result = await fetchContainers()
            containers = result
            if result.isEmpty {
                let (responsive, reason) = await checkDockerStatus()
                isAvailable = responsive
                unavailableReason = reason
            } else {
                isAvailable = true
                unavailableReason = .none
            }
            autoPin()
        }
    }

    /// Check docker status and return availability + reason if unavailable
    private func checkDockerStatus() async -> (available: Bool, reason: DockerUnavailableReason) {
        let env = dockerEnv
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "\(Self.dockerBinary) info 2>&1"]
                process.standardOutput = pipe
                process.standardError = pipe
                var procEnv = ProcessInfo.processInfo.environment
                procEnv["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin"
                if let extra = env {
                    for (k, v) in extra { procEnv[k] = v }
                }
                process.environment = procEnv

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: (true, .none))
                    } else if output.contains("permission denied") {
                        continuation.resume(returning: (false, .permissionDenied))
                    } else if output.contains("Is the docker daemon running") || output.contains("Cannot connect") {
                        continuation.resume(returning: (false, .daemonNotRunning))
                    } else if output.contains("No such file") || output.contains("no such file") {
                        continuation.resume(returning: (false, .socketNotFound))
                    } else {
                        continuation.resume(returning: (false, .unknown))
                    }
                } catch {
                    continuation.resume(returning: (false, .unknown))
                }
            }
        }
    }

    // MARK: - Container Actions

    func startContainer(_ id: String) {
        runDockerAction("start", id: id)
    }

    func stopContainer(_ id: String) {
        runDockerAction("stop", id: id)
    }

    func pauseContainer(_ id: String) {
        runDockerAction("pause", id: id)
    }

    func unpauseContainer(_ id: String) {
        runDockerAction("unpause", id: id)
    }

    func openShell(_ id: String) {
        if let env = dockerEnv, let host = env["DOCKER_HOST"] {
            openTerminalWithCommand("DOCKER_HOST=\(host) \(Self.dockerBinary) exec -it \(id) /bin/sh")
        } else {
            openTerminalWithCommand("\(Self.dockerBinary) exec -it \(id) /bin/sh")
        }
    }

    func inspectContainer(_ id: String) async -> String {
        let env = dockerEnv
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = runShellCommand("\(Self.dockerBinary) inspect \(id)", extraEnv: env)
                continuation.resume(returning: output)
            }
        }
    }

    func streamLogs(for id: String, handler: @escaping (String) -> Void) -> Process {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(Self.dockerBinary) logs -f --tail 200 \(id)"]
        process.standardOutput = pipe
        process.standardError = pipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin"
        if let extra = dockerEnv {
            for (k, v) in extra { environment[k] = v }
        }
        process.environment = environment

        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    handler(text)
                }
            }
        }

        try? process.run()
        return process
    }

    // MARK: - Pinning

    func pin(_ containerId: String) {
        guard !pinnedContainerIds.contains(containerId) else { return }
        if pinnedContainerIds.count >= maxPins {
            evictPin()
        }
        pinnedContainerIds.append(containerId)
        manuallyUnpinned.remove(containerId)  // Clear unpinned state when manually pinning
        saveDockerConfig()
    }

    func unpin(_ containerId: String) {
        pinnedContainerIds.removeAll { $0 == containerId }
        manuallyUnpinned.insert(containerId)
        saveDockerConfig()
    }

    func isPinned(_ containerId: String) -> Bool {
        pinnedContainerIds.contains(containerId)
    }

    // MARK: - Private

    private func runDockerAction(_ action: String, id: String) {
        let env = dockerEnv
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runShellCommand("\(Self.dockerBinary) \(action) \(id)", extraEnv: env)
        }
        startFastPolling()
    }

    private func startFastPolling() {
        fastPollTimer?.invalidate()
        fastPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        // Stop fast polling after 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.fastPollTimer?.invalidate()
            self?.fastPollTimer = nil
        }
    }

    private func fetchContainers() async -> [DockerContainer] {
        let env = dockerEnv
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = runShellCommand("\(Self.dockerBinary) ps -a --format '{{json .}}'", extraEnv: env)
                var result: [DockerContainer] = []

                for line in output.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty,
                          let data = trimmed.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }

                    let fullId = json["ID"] as? String ?? ""
                    let state = json["State"] as? String ?? ""
                    let container = DockerContainer(
                        id: fullId,
                        shortId: String(fullId.prefix(12)),
                        name: json["Names"] as? String ?? "",
                        image: json["Image"] as? String ?? "",
                        status: ContainerStatus(from: state),
                        statusText: json["Status"] as? String ?? "",
                        ports: json["Ports"] as? String ?? "",
                        created: json["CreatedAt"] as? String ?? ""
                    )
                    result.append(container)
                }

                continuation.resume(returning: result)
            }
        }
    }

    private func dockerIsResponsive() async -> Bool {
        let extraEnv = dockerEnv
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "\(Self.dockerBinary) info > /dev/null 2>&1"]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin"
                if let extra = extraEnv {
                    for (k, v) in extra { env[k] = v }
                }
                process.environment = env
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func autoPin() {
        // Clean up manuallyUnpinned for containers that are no longer running
        // (so if they start again later, they get auto-pinned again)
        let runningIds = Set(containers.filter { $0.status == .running }.map(\.id))
        let before = manuallyUnpinned
        manuallyUnpinned = manuallyUnpinned.intersection(runningIds)
        if manuallyUnpinned != before { saveDockerConfig() }

        for container in containers where container.status == .running {
            if !manuallyUnpinned.contains(container.id)
                && !pinnedContainerIds.contains(container.id)
                && !pinnedContainerIds.contains(container.name) {
                pin(container.id)
            }
        }
    }

    /// Number of running containers not shown in pinned list
    var unpinnedRunningCount: Int {
        containers.filter { c in
            c.status == .running && !pinnedContainerIds.contains(c.id) && !pinnedContainerIds.contains(c.name)
        }.count
    }

    private func evictPin() {
        // Evict oldest stopped, then paused, then running
        let priorities: [ContainerStatus] = [.exited, .created, .other, .paused, .running]
        for targetStatus in priorities {
            for pinId in pinnedContainerIds {
                if let container = containers.first(where: { $0.id == pinId || $0.name == pinId }),
                   container.status == targetStatus {
                    pinnedContainerIds.removeAll { $0 == pinId }
                    return
                }
            }
        }
        // Fallback: remove first (oldest)
        if !pinnedContainerIds.isEmpty {
            pinnedContainerIds.removeFirst()
        }
    }

    /// Docker config structure for consolidated file
    private struct DockerConfig: Codable {
        var pinned: [String] = []
        var unpinned: [String] = []
    }

    private func loadDockerConfig() {
        let fm = FileManager.default

        // Try loading from new consolidated file first
        if let data = try? Data(contentsOf: Self.dockerFile),
           let config = try? JSONDecoder().decode(DockerConfig.self, from: data) {
            pinnedContainerIds = config.pinned
            manuallyUnpinned = Set(config.unpinned)
            return
        }

        // Migrate from legacy files if they exist
        var migrated = false

        if let data = try? Data(contentsOf: Self.legacyPinsFile),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            pinnedContainerIds = ids
            migrated = true
        }

        if let data = try? Data(contentsOf: Self.legacyUnpinnedFile),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            manuallyUnpinned = Set(ids)
            migrated = true
        }

        if migrated {
            // Save to new format and remove legacy files
            saveDockerConfig()
            try? fm.removeItem(at: Self.legacyPinsFile)
            try? fm.removeItem(at: Self.legacyUnpinnedFile)
        }
    }

    private func saveDockerConfig() {
        let config = DockerConfig(
            pinned: pinnedContainerIds,
            unpinned: Array(manuallyUnpinned)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            try? data.write(to: Self.dockerFile)
        }
    }
}
