#!/bin/bash
#
# Create macOS app icons using SF Symbols or custom PNG images
#
# Usage:
#   ./create-icon.sh [options]
#
# Options:
#   -s, --symbol NAME        SF Symbol name (default: shippingbox.fill)
#   -f, --file PATH          PNG image file (used instead of SF Symbol, preserves colors)
#   -o, --output PATH        Output .icns file (default: Sources/AppIcon.icns)
#   -c, --color COLOR        Solid background color (default: gradient)
#   -g, --gradient FROM TO   Gradient background colors (default: #3380e6 #4d4dcc)
#   -a, --angle DEGREES      Gradient angle in degrees (default: -45)
#   -i, --icon-color COLOR   Icon/symbol color (default: #ffffff) (ignored with -f)
#   -z, --icon-scale FLOAT   Icon scale factor, >1 enlarge, <1 shrink (default: 1.0)
#   -r, --corner-radius PCT  Corner radius as % of icon size (default: 20)
#   -p, --preview            Preview mode: generate a single 512px PNG and open it
#   -h, --help               Show this help
#
# Colors can be specified as:
#   #rgb        e.g. #fd4
#   #rrggbb     e.g. #ffdd44
#   r,g,b       e.g. 0.2,0.5,0.9  (0.0-1.0 float values)
#
# Examples:
#   ./create-icon.sh -p -s gear -c '#1a1a1a' -i '#e6b300'
#   ./create-icon.sh -s shield.lefthalf.fill
#   ./create-icon.sh -s cloud.fill -g '#36c' '#1a4d99' -z 1.2
#   ./create-icon.sh -s leaf.fill -c '#39b34a' -r 30 -o MyApp.icns
#   ./create-icon.sh -p -f icon.png -g '#014' '#02b' -z 0.9
#

set -e

# Defaults
SYMBOL="smallcircle.fill.circle.fill"
IMAGE_FILE=""
OUTPUT="Sources/AppIcon.icns"
BG_MODE="gradient"
SOLID_COLOR=""
GRAD_FROM="#014"
GRAD_TO="#02b"
GRAD_ANGLE="20"
ICON_COLOR="#9bf"
ICON_SCALE="1.0"
CORNER_RADIUS="20"
PREVIEW_MODE="false"

show_help() {
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
    exit 0
}

# Normalize any color format to R,G,B floats (0.0-1.0)
normalize_color() {
    local val="$1"
    local name="$2"

    # Already in float R,G,B format
    if echo "$val" | grep -qE '^[0-9.]+,[0-9.]+,[0-9.]+$'; then
        echo "$val"
        return
    fi

    # Strip leading #
    local hex="${val#\#}"

    # Expand shorthand #rgb to #rrggbb
    if [ ${#hex} -eq 3 ]; then
        hex="${hex:0:1}${hex:0:1}${hex:1:1}${hex:1:1}${hex:2:1}${hex:2:1}"
    fi

    if [ ${#hex} -ne 6 ]; then
        echo "Error: $name '$val' is not a valid color. Use #rgb, #rrggbb, or r,g,b" >&2
        exit 1
    fi

    # Convert hex to 0.0-1.0 floats
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    printf "%.4f,%.4f,%.4f" "$(echo "$r/255" | bc -l)" "$(echo "$g/255" | bc -l)" "$(echo "$b/255" | bc -l)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--symbol)       SYMBOL="$2"; shift 2 ;;
        -f|--file)         IMAGE_FILE="$2"; shift 2 ;;
        -o|--output)       OUTPUT="$2"; shift 2 ;;
        -c|--color)        BG_MODE="solid"; SOLID_COLOR="$2"; shift 2 ;;
        -g|--gradient)     BG_MODE="gradient"; GRAD_FROM="$2"; GRAD_TO="$3"; shift 3 ;;
        -a|--angle)        GRAD_ANGLE="$2"; shift 2 ;;
        -i|--icon-color)   ICON_COLOR="$2"; shift 2 ;;
        -z|--icon-scale)   ICON_SCALE="$2"; shift 2 ;;
        -r|--corner-radius) CORNER_RADIUS="$2"; shift 2 ;;
        -p|--preview)      PREVIEW_MODE="true"; shift ;;
        -h|--help)         show_help ;;
        *)                 echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Validate image file if specified
if [ -n "$IMAGE_FILE" ]; then
    if [ ! -f "$IMAGE_FILE" ]; then
        echo "Error: image file '$IMAGE_FILE' not found" >&2
        exit 1
    fi
    # Resolve to absolute path for Swift
    IMAGE_FILE="$(cd "$(dirname "$IMAGE_FILE")" && pwd)/$(basename "$IMAGE_FILE")"
fi

# Normalize all colors to R,G,B float format for Swift
ICON_COLOR=$(normalize_color "$ICON_COLOR" "icon-color")
if [ "$BG_MODE" = "solid" ]; then
    SOLID_COLOR=$(normalize_color "$SOLID_COLOR" "color")
else
    GRAD_FROM=$(normalize_color "$GRAD_FROM" "gradient-from")
    GRAD_TO=$(normalize_color "$GRAD_TO" "gradient-to")
fi

WORK_DIR=$(mktemp -d)

if [ "$PREVIEW_MODE" = "true" ]; then
    PREVIEW_FILE="$WORK_DIR/preview_512.png"
else
    ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
fi

# Pass parameters to Swift via environment
export ICON_SYMBOL="$SYMBOL"
export ICON_IMAGE_FILE="$IMAGE_FILE"
export ICON_BG_MODE="$BG_MODE"
export ICON_SOLID_COLOR="$SOLID_COLOR"
export ICON_GRAD_FROM="$GRAD_FROM"
export ICON_GRAD_TO="$GRAD_TO"
export ICON_GRAD_ANGLE="$GRAD_ANGLE"
export ICON_COLOR="$ICON_COLOR"
export ICON_SCALE="$ICON_SCALE"
export ICON_CORNER_RADIUS="$CORNER_RADIUS"
export ICON_PREVIEW_MODE="$PREVIEW_MODE"
export ICON_OUTDIR="$WORK_DIR"

swift - <<'SWIFT'
import AppKit

func env(_ key: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? ""
}

func parseRGB(_ s: String) -> (CGFloat, CGFloat, CGFloat) {
    let parts = s.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 3 else { return (0, 0, 0) }
    return (CGFloat(parts[0]), CGFloat(parts[1]), CGFloat(parts[2]))
}

let symbol = env("ICON_SYMBOL")
let imageFile = env("ICON_IMAGE_FILE")
let bgMode = env("ICON_BG_MODE")
let iconScale = Double(env("ICON_SCALE")) ?? 1.0
let cornerRadius = Double(env("ICON_CORNER_RADIUS")) ?? 20.0
let gradAngle = CGFloat(Double(env("ICON_GRAD_ANGLE")) ?? -45.0)
let outDir = env("ICON_OUTDIR")
let previewMode = env("ICON_PREVIEW_MODE") == "true"

let (iconR, iconG, iconB) = parseRGB(env("ICON_COLOR"))
let iconColor = NSColor(red: iconR, green: iconG, blue: iconB, alpha: 1.0)

// Load custom image if specified
let customImage: NSImage? = imageFile.isEmpty ? nil : NSImage(contentsOfFile: imageFile)
if !imageFile.isEmpty && customImage == nil {
    fputs("Error: could not load image '\(imageFile)'\n", stderr)
    exit(1)
}

let sizes: [(Int, String)]
if previewMode {
    sizes = [(512, "preview_512.png")]
} else {
    sizes = [
        (16, "AppIcon.iconset/icon_16x16.png"),
        (32, "AppIcon.iconset/icon_16x16@2x.png"),
        (32, "AppIcon.iconset/icon_32x32.png"),
        (64, "AppIcon.iconset/icon_32x32@2x.png"),
        (128, "AppIcon.iconset/icon_128x128.png"),
        (256, "AppIcon.iconset/icon_128x128@2x.png"),
        (256, "AppIcon.iconset/icon_256x256.png"),
        (512, "AppIcon.iconset/icon_256x256@2x.png"),
        (512, "AppIcon.iconset/icon_512x512.png"),
        (1024, "AppIcon.iconset/icon_512x512@2x.png")
    ]
}

for (size, filename) in sizes {
    let s = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let image = NSImage(size: rect.size)

    image.lockFocus()

    // Background rounded rectangle
    let inset = s * 0.05
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let radius = s * CGFloat(cornerRadius) / 100.0
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)

    if bgMode == "solid" {
        let (r, g, b) = parseRGB(env("ICON_SOLID_COLOR"))
        NSColor(red: r, green: g, blue: b, alpha: 1.0).setFill()
        bgPath.fill()
    } else {
        let (r1, g1, b1) = parseRGB(env("ICON_GRAD_FROM"))
        let (r2, g2, b2) = parseRGB(env("ICON_GRAD_TO"))
        let gradient = NSGradient(colors: [
            NSColor(red: r1, green: g1, blue: b1, alpha: 1.0),
            NSColor(red: r2, green: g2, blue: b2, alpha: 1.0)
        ])
        gradient?.draw(in: bgPath, angle: gradAngle)
    }

    if let customImage = customImage {
        // Draw custom PNG image — preserve original colors, fit into icon area
        let naturalSize = customImage.size
        let aspectRatio = naturalSize.width / naturalSize.height
        let targetSize = s * 0.6 * CGFloat(iconScale)

        let drawWidth: CGFloat
        let drawHeight: CGFloat
        if aspectRatio > 1 {
            drawWidth = targetSize
            drawHeight = targetSize / aspectRatio
        } else {
            drawWidth = targetSize * aspectRatio
            drawHeight = targetSize
        }

        let drawRect = NSRect(
            x: round((s - drawWidth) / 2),
            y: round((s - drawHeight) / 2),
            width: round(drawWidth),
            height: round(drawHeight)
        )

        customImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    } else if let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
        // Draw SF Symbol - always render at high resolution, then scale down for consistency
        let refSize: CGFloat = 512
        let refPointSize = refSize * 0.5 * CGFloat(iconScale)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: refPointSize, weight: .medium)
        guard let configuredSymbol = symbolImage.withSymbolConfiguration(symbolConfig) else { continue }

        // Get aspect ratio from the high-res rendering
        let naturalSize = configuredSymbol.size
        let aspectRatio = naturalSize.width / naturalSize.height
        let refTargetSize = refSize * 0.6 * CGFloat(iconScale)

        let refWidth: CGFloat
        let refHeight: CGFloat
        if aspectRatio > 1 {
            refWidth = refTargetSize
            refHeight = refTargetSize / aspectRatio
        } else {
            refWidth = refTargetSize * aspectRatio
            refHeight = refTargetSize
        }

        // Create tinted symbol at reference size
        let tintImage = NSImage(size: NSSize(width: refWidth, height: refHeight))
        tintImage.lockFocus()
        let localRect = NSRect(x: 0, y: 0, width: refWidth, height: refHeight)
        configuredSymbol.draw(in: localRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        iconColor.set()
        localRect.fill(using: .sourceAtop)
        tintImage.unlockFocus()

        // Scale down to target icon size
        let scale = s / refSize
        let drawWidth = refWidth * scale
        let drawHeight = refHeight * scale

        // Calculate position without rounding first
        let calib = (x: 0.35, y: 0.15)  // some calibration
        let xPosition = (s - drawWidth + calib.x) / 2
        let yPosition = (s - drawHeight + calib.y) / 2

        // Round only the final values for the symbolRect
        let symbolRect = NSRect(
            x: round(xPosition),
            y: round(yPosition),
            width: round(drawWidth),
            height: round(drawHeight)
        )

        tintImage.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    image.unlockFocus()

    // Save as PNG
    if let tiffData = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiffData),
       let pngData = bitmap.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: "\(outDir)/\(filename)")
        try? pngData.write(to: url)
    }
}
SWIFT

if [ "$PREVIEW_MODE" = "true" ]; then
    echo "Preview: $PREVIEW_FILE"
    open "$PREVIEW_FILE"
else
    # Convert iconset to icns
    ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
    if [ -d "$ICONSET_DIR" ]; then
        mkdir -p "$(dirname "$OUTPUT")"
        iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT"
        echo "Created $OUTPUT"
        rm -rf "$WORK_DIR"
    else
        echo "Failed to create iconset" >&2
        rm -rf "$WORK_DIR"
        exit 1
    fi
fi
