import Foundation

/// Shared shell command utility used by both ColimaManager and DockerManager
func runShellCommand(_ command: String, extraEnv: [String: String]? = nil) -> String {
    let process = Process()
    let pipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = pipe
    process.standardError = pipe

    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin"
    if let extra = extraEnv {
        for (k, v) in extra { environment[k] = v }
    }
    process.environment = environment

    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}

/// Opens Terminal.app and runs a command (with optional sudo for another user)
func openTerminalWithCommand(_ command: String) {
    let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]

    try? process.run()
}

enum ColimaStatus: String, Equatable {
    case running = "Running"
    case stopped = "Stopped"
    case starting = "Starting..."
    case stopping = "Stopping..."
    case unknown = "Unknown"

    var isRunning: Bool { self == .running }
    var isStopped: Bool { self == .stopped || self == .unknown }
    var isTransitioning: Bool { self == .starting || self == .stopping }
    var isStarting: Bool { self == .starting }
    var isStopping: Bool { self == .stopping }
}

struct ColimaInstance: Identifiable, Equatable {
    let id: String
    let name: String
    var status: ColimaStatus
    var cpu: Int?
    var memory: Int?  // in GiB
    var disk: Int?    // in GiB

    /// Status and resource lines for menu display
    var statusLines: [String] {
        var lines = ["Status: \(status.rawValue)"]
        if let cpu = cpu { lines.append("CPUs: \(cpu)") }
        if let memory = memory { lines.append("Memory: \(memory) GB") }
        if let disk = disk { lines.append("Disk: \(disk) GB") }
        return lines
    }
}

/// Manages the configured colima user setting
struct ColimaConfig {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/cd-player")
    private static let configFile = configDir.appendingPathComponent("config.json")

    private static func loadConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private static func saveConfig(_ config: [String: Any]) {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: config, options: .prettyPrinted) {
            try? data.write(to: configFile)
        }
    }

    static func getColimaUser() -> String? {
        let config = loadConfig()
        guard let user = config["colimaUser"] as? String, !user.isEmpty else {
            return nil
        }
        return user
    }

    static func setColimaUser(_ user: String?) {
        var config = loadConfig()
        if let user = user, !user.isEmpty {
            config["colimaUser"] = user
        } else {
            config.removeValue(forKey: "colimaUser")
        }
        saveConfig(config)
    }

    /// Whether to automatically set group read/write permissions on docker.sock after colima starts
    static func getAutoFixSocketPermissions() -> Bool {
        let config = loadConfig()
        return config["autoFixSocketPermissions"] as? Bool ?? false
    }

    static func setAutoFixSocketPermissions(_ enabled: Bool) {
        var config = loadConfig()
        config["autoFixSocketPermissions"] = enabled
        saveConfig(config)
    }

    /// Check if a user exists by verifying /Users/<username> exists
    static func userExists(_ username: String) -> Bool {
        var isDir: ObjCBool = false
        let path = "/Users/\(username)"
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

@MainActor
final class ColimaManager: ObservableObject {
    @Published private(set) var instances: [ColimaInstance] = []
    @Published private(set) var isLoading = true
    @Published private(set) var configuredUser: String?

    private var statusCheckTimer: Timer?
    private var fastPollTimer: Timer?
    private let currentUser = ProcessInfo.processInfo.userName

    /// Tracks profiles in transition: profile name -> (transitioning status, expected final status, start time)
    private var transitioningProfiles: [String: (current: ColimaStatus, expected: ColimaStatus, startTime: Date)] = [:]
    /// Minimum seconds a transition must last before it can be cleared (allows time for Terminal/sudo)
    private let minTransitionSeconds: TimeInterval = 5.0

    var hasRunningInstance: Bool {
        instances.contains { $0.status.isRunning }
    }

    /// Whether we have only the default profile (for simplified UI)
    var hasOnlyDefaultProfile: Bool {
        instances.count == 1 && instances.first?.name == "default"
    }

    /// The effective colima user (configured user, or current user if not configured)
    var effectiveUser: String {
        configuredUser ?? currentUser
    }

    /// Whether we need sudo (configured user differs from current user)
    var needsSudo: Bool {
        guard let configured = configuredUser else { return false }
        return configured != currentUser
    }

    init() {
        configuredUser = ColimaConfig.getColimaUser()
        startStatusChecking()
    }

    /// Set the colima user. Returns error message if validation fails.
    func setColimaUser(_ user: String?) -> String? {
        if let user = user, !user.isEmpty {
            guard ColimaConfig.userExists(user) else {
                return "User '\(user)' does not exist"
            }
        }
        ColimaConfig.setColimaUser(user)
        configuredUser = user
        refreshStatus()
        return nil
    }

    deinit {
        statusCheckTimer?.invalidate()
    }

    func startStatusChecking() {
        refreshStatus()
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
    }

    func refreshStatus() {
        Task {
            var profiles = await getColimaProfiles()
            let now = Date()

            // Apply transitioning states where the expected final state hasn't been reached yet
            for i in profiles.indices {
                let profile = profiles[i]
                if let transition = transitioningProfiles[profile.name] {
                    let elapsed = now.timeIntervalSince(transition.startTime)
                    let minTimePassed = elapsed >= minTransitionSeconds

                    if profile.status == transition.expected && minTimePassed {
                        // Reached expected state and minimum time passed - clear transition
                        transitioningProfiles.removeValue(forKey: profile.name)
                        // Check if we should stop fast polling
                        if transitioningProfiles.isEmpty {
                            stopFastPolling()
                        }
                    } else {
                        // Still transitioning - show transitioning status but preserve resource info
                        profiles[i] = ColimaInstance(
                            id: profile.id,
                            name: profile.name,
                            status: transition.current,
                            cpu: profile.cpu,
                            memory: profile.memory,
                            disk: profile.disk
                        )
                    }
                }
            }

            instances = profiles
            isLoading = false
        }
    }

    /// Get profiles by scanning the configured user's colima directory
    /// and checking running status via ps aux
    private func getColimaProfiles() async -> [ColimaInstance] {
        // Get known profiles from directory (with resource info)
        let knownProfiles = getProfilesFromColimaDir()

        // Get running profiles from ps aux
        let runningProfiles = await getRunningProfiles()

        // Build instances
        var instancesByName: [String: ColimaInstance] = [:]

        // Add known profiles with their resource info
        for config in knownProfiles {
            let status: ColimaStatus = runningProfiles.contains(config.name) ? .running : .stopped
            instancesByName[config.name] = ColimaInstance(
                id: config.name,
                name: config.name,
                status: status,
                cpu: config.cpu,
                memory: config.memory,
                disk: config.disk
            )
        }

        // Add any running profiles not in directory (edge case)
        for name in runningProfiles {
            if instancesByName[name] == nil {
                instancesByName[name] = ColimaInstance(id: name, name: name, status: .running)
            }
        }

        // Sort: 'default' first, then alphabetically
        var results = Array(instancesByName.values)
        results.sort { a, b in
            if a.name == "default" { return true }
            if b.name == "default" { return false }
            return a.name < b.name
        }

        return results
    }

    /// Profile info read from colima.yaml
    private struct ProfileConfig {
        let name: String
        var cpu: Int?
        var memory: Int?
        var disk: Int?
    }

    /// Get profile configs by scanning the colima user's directory
    private func getProfilesFromColimaDir() -> [ProfileConfig] {
        let colimaHome = URL(fileURLWithPath: "/Users/\(effectiveUser)/.colima")

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: colimaHome, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var profiles: [ProfileConfig] = []
        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.hasPrefix("_") { continue }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let configFile = url.appendingPathComponent("colima.yaml")
                if fm.fileExists(atPath: configFile.path) {
                    var config = ProfileConfig(name: name)
                    // Parse colima.yaml for resource values
                    if let yamlContent = try? String(contentsOf: configFile, encoding: .utf8) {
                        config.cpu = parseYamlInt(yamlContent, key: "cpu")
                        config.memory = parseYamlInt(yamlContent, key: "memory")
                        config.disk = parseYamlInt(yamlContent, key: "disk")
                    }
                    profiles.append(config)
                }
            }
        }

        return profiles
    }

    /// Simple YAML integer parser (looks for "key: value" pattern)
    private func parseYamlInt(_ content: String, key: String) -> Int? {
        let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: key) + ":\\s*(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let valueRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return Int(content[valueRange])
    }

    /// Get running profile names from ps aux
    private func getRunningProfiles() async -> Set<String> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = runShellCommand("ps aux | grep 'colima daemon start' | grep -v grep")
                var running: Set<String> = []

                for line in output.components(separatedBy: "\n") {
                    guard !line.isEmpty else { continue }
                    if let range = line.range(of: "colima daemon start ") {
                        let afterStart = line[range.upperBound...]
                        let profilePart = afterStart.components(separatedBy: .whitespaces).first ?? ""
                        if !profilePart.isEmpty && !profilePart.hasPrefix("-") {
                            running.insert(profilePart)
                        }
                    }
                }

                continuation.resume(returning: running)
            }
        }
    }

    func start(profile: String) {
        // Track this transition: starting -> expect running
        transitioningProfiles[profile] = (current: .starting, expected: .running, startTime: Date())
        // Immediately update UI
        updateInstanceStatus(profile: profile, status: .starting)
        startFastPolling()

        if needsSudo {
            openTerminalWithColimaStart(profile: profile)
        } else {
            runColimaDirectly(["start", "-p", profile])
        }
    }

    func stop(profile: String) {
        // Track this transition: stopping -> expect stopped
        transitioningProfiles[profile] = (current: .stopping, expected: .stopped, startTime: Date())
        // Immediately update UI
        updateInstanceStatus(profile: profile, status: .stopping)
        startFastPolling()

        if needsSudo {
            openTerminalWithColimaCommand("stop -p \(profile)")
        } else {
            runColimaDirectly(["stop", "-p", profile])
        }
    }

    /// Immediately update the status of a specific instance in the UI
    private func updateInstanceStatus(profile: String, status: ColimaStatus) {
        if let index = instances.firstIndex(where: { $0.name == profile }) {
            var newInstances = instances
            let existing = newInstances[index]
            newInstances[index] = ColimaInstance(
                id: profile,
                name: profile,
                status: status,
                cpu: existing.cpu,
                memory: existing.memory,
                disk: existing.disk
            )
            instances = newInstances
        }
    }

    /// Start fast polling (every 1 second) to catch state changes
    private func startFastPolling() {
        // Cancel any existing fast poll timer
        fastPollTimer?.invalidate()

        // Poll every 1 second
        fastPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
            }
        }
    }

    /// Stop fast polling and return to normal interval
    private func stopFastPolling() {
        fastPollTimer?.invalidate()
        fastPollTimer = nil
    }

    /// Run colima command directly (when current user is the colima owner)
    private func runColimaDirectly(_ args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()

            let colimaPath = [
                "/opt/homebrew/bin/colima",
                "/usr/local/bin/colima",
                "/usr/bin/colima"
            ].first { FileManager.default.fileExists(atPath: $0) } ?? "colima"

            process.executableURL = URL(fileURLWithPath: colimaPath)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = pipe

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = environment

            do {
                try process.run()
                // Don't wait - let the fast polling detect when it's done
            } catch {
                // Ignore errors
            }
        }
    }

    /// Opens Terminal.app and runs the colima command (with sudo if configured)
    private func openTerminalWithColimaCommand(_ args: String) {
        let command: String
        if let user = configuredUser {
            command = "sudo -Hu \(user) colima \(args)"
        } else {
            command = "colima \(args)"
        }
        openTerminalWithCommand(command)
    }

    /// Start colima with optional chmod to fix socket permissions
    private func openTerminalWithColimaStart(profile: String) {
        guard let user = configuredUser else {
            openTerminalWithCommand("colima start -p \(profile)")
            return
        }

        let colimaStart = "sudo -Hu \(user) colima start -p \(profile)"

        if ColimaConfig.getAutoFixSocketPermissions() {
            let socketPath = "/Users/\(user)/.colima/\(profile)/docker.sock"
            // Chain: start colima, then fix socket permissions
            let command = "\(colimaStart) && sudo chmod g+rw \(socketPath) && echo 'Socket permissions updated.'"
            openTerminalWithCommand(command)
        } else {
            openTerminalWithCommand(colimaStart)
        }
    }
}
