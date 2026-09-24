import Cocoa

extension Notification.Name {
    static let toolbarColorsDidChange = Notification.Name("toolbarColorsDidChange")
}

// Toolbar buttons drawn directly in the OverlayView (not a separate window).
// This avoids window-level z-order issues and matches Flameshot's look.

enum ToolbarButtonAction {
    case tool(AnnotationTool)
    case color
    case sizeDisplay
    case undo
    case redo
    case copy
    case save
    case pin
    case ocr
    case autoRedact
    case beautify
    case beautifyStyle
    case cancel
    case moveSelection
    case adjustSelection
    case delayCapture
    case upload
    case share
    case removeBackground
    case invertColors
    case loupe
    case translate
    case record  // enters recording mode (shows recording toolbar)
    case startRecord  // actually starts recording
    case stopRecord
    case mouseHighlight
    case systemAudio
    case micAudio
    case detach
    case scrollCapture
    case addCapture  // editor only: capture a new region and append to the canvas
    case showKeystrokes
    case webcam
    case recordSettings  // recording mode: open format/FPS/when-done popover
    case effects  // image effects (CIFilter adjustments + presets)
}

struct ToolbarButton {
    let action: ToolbarButtonAction
    let sfSymbol: String?
    let tooltip: String
    var isSelected: Bool = false
    var tintColor: NSColor = ToolbarLayout.iconColor
    var selectedTintColor: NSColor? = nil  // optional status tint that remains visible while selected
    var bgColor: NSColor? = nil  // for color swatches
    var hasContextMenu: Bool = false  // draw small corner triangle to indicate right-click options
}

enum ToolbarCustomAction: Int {
    #if !OFFLINE
    case upload = 1001
    #endif
    case pin = 1002
    case ocr = 1003
    case beautify = 1004
    case removeBackground = 1005
    case autoRedact = 1006
    case reserved1007 = 1007
    case translate = 1008
    case record = 1009
    case scrollCapture = 1010
    case invertColors = 1011
    case share = 1012
    case effects = 1013

    static var allKnownActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = []
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [
            .pin, .ocr, .beautify, .removeBackground, .autoRedact, .reserved1007,
            .translate, .record, .scrollCapture, .invertColors, .share, .effects,
        ])
        return actions
    }

    static var bottomToolbarActions: [ToolbarCustomAction] {
        [.invertColors, .effects, .beautify, .removeBackground]
    }

    static var rightToolbarActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = [.share]
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [.pin, .ocr, .translate, .scrollCapture, .record])
        return actions
    }

    static var bottomSettingsActions: [ToolbarCustomAction] {
        bottomToolbarActions
    }

    static var rightSettingsActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = []
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [.pin, .ocr, .autoRedact, .translate, .record, .scrollCapture, .share])
        return actions
    }

    var settingsLabel: String {
        switch self {
        #if !OFFLINE
        case .upload: return L("Upload")
        #endif
        case .pin: return L("Pin (floating window)")
        case .ocr: return L("OCR & QR")
        case .beautify: return L("Beautify")
        case .removeBackground: return L("Remove Background")
        case .autoRedact: return L("Auto-Redact sensitive data")
        case .reserved1007: return ""
        case .translate: return L("Translate")
        case .record: return L("Record screen")
        case .scrollCapture: return L("Scroll Capture")
        case .invertColors: return L("Invert Colors")
        case .share: return L("Share")
        case .effects: return L("Adjust (Image Effects)")
        }
    }

    func makeToolbarButton(
        beautifyEnabled: Bool = false,
        translateEnabled: Bool = false,
        effectsActive: Bool = false,
        isRecording: Bool = false,
        isEditorMode: Bool = false
    ) -> ToolbarButton? {
        switch self {
        #if !OFFLINE
        case .upload:
            var button = ToolbarButton(action: .upload, sfSymbol: "icloud.and.arrow.up", tooltip: L("Upload"))
            button.hasContextMenu = true
            return button
        #endif
        case .pin:
            return ToolbarButton(action: .pin, sfSymbol: "pin.fill", tooltip: L("Pin"))
        case .ocr:
            return ToolbarButton(action: .ocr, sfSymbol: "doc.text.viewfinder", tooltip: L("OCR & QR"))
        case .beautify:
            var button = ToolbarButton(action: .beautify, sfSymbol: "sparkles", tooltip: L("Beautify"))
            if beautifyEnabled {
                let enabledColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
                button.tintColor = enabledColor
                button.selectedTintColor = enabledColor
            }
            return button
        case .removeBackground:
            if #available(macOS 14.0, *) {
                return ToolbarButton(
                    action: .removeBackground,
                    sfSymbol: "person.crop.circle.dashed",
                    tooltip: L("Remove Background")
                )
            }
            return nil
        case .autoRedact, .reserved1007:
            return nil
        case .translate:
            var button = ToolbarButton(action: .translate, sfSymbol: "translate", tooltip: L("Translate"))
            button.isSelected = translateEnabled
            button.hasContextMenu = true
            return button
        case .record:
            guard !isEditorMode else { return nil }
            var button = ToolbarButton(action: .record, sfSymbol: "video.fill", tooltip: L("Record"))
            button.tintColor = ToolbarLayout.iconColor
            return button
        case .scrollCapture:
            guard !isRecording && !isEditorMode else { return nil }
            return ToolbarButton(action: .scrollCapture, sfSymbol: "scroll", tooltip: L("Scroll Capture"))
        case .invertColors:
            return ToolbarButton(
                action: .invertColors,
                sfSymbol: "circle.righthalf.filled.inverse",
                tooltip: L("Invert Colors")
            )
        case .share:
            return ToolbarButton(action: .share, sfSymbol: "square.and.arrow.up", tooltip: L("Share"))
        case .effects:
            var button = ToolbarButton(action: .effects, sfSymbol: "slider.horizontal.3", tooltip: L("Adjust"))
            if effectsActive {
                button.tintColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }
            return button
        }
    }
}

enum ToolbarActionPreferences {
    static let enabledDefaultsKey = "enabledActions"
    static let knownDefaultsKey = "knownActionTags"

    static var allKnownRawValues: [Int] {
        ToolbarCustomAction.allKnownActions.map(\.rawValue)
    }

    static var defaultEnabledRawValues: [Int] {
        allKnownRawValues
    }

    static func enabledRawValuesAfterMigration() -> [Int]? {
        var enabledActions = UserDefaults.standard.array(forKey: enabledDefaultsKey) as? [Int]
        let knownActionTags = UserDefaults.standard.array(forKey: knownDefaultsKey) as? [Int]
        let newTags = allKnownRawValues.filter { !(knownActionTags ?? []).contains($0) }

        if !newTags.isEmpty {
            if enabledActions == nil {
                enabledActions = allKnownRawValues
            } else if knownActionTags == nil {
                // Upgrading from a version before knownActionTags tracking was added.
            } else {
                enabledActions = enabledActions! + newTags
            }
            UserDefaults.standard.set(enabledActions, forKey: enabledDefaultsKey)
            UserDefaults.standard.set(allKnownRawValues, forKey: knownDefaultsKey)
        }

        return enabledActions
    }

    static func isEnabled(_ action: ToolbarCustomAction, in enabledActions: [Int]?) -> Bool {
        enabledActions == nil || enabledActions!.contains(action.rawValue)
    }
}

class ToolbarLayout {

    // Default theme: the Flameshot purple accent on a surface that follows the
    // system appearance — light bar and dark glyphs in Light mode, dark bar
    // and light glyphs in Dark mode. A colour picked in Settings is stored and
    // wins over these. Resolved when read rather than as a dynamic NSColor,
    // because many surfaces copy the colour into a layer when they are built,
    // outside any drawing pass that would resolve it.
    static let defaultAccentColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)
    static var defaultIconColor: NSColor {
        isSystemDark ? NSColor(white: 0.94, alpha: 1.0) : NSColor(white: 0.17, alpha: 1.0)
    }
    static var defaultBgColor: NSColor {
        isSystemDark ? NSColor(white: 0.15, alpha: 1.0) : NSColor(white: 0.985, alpha: 1.0)
    }
    /// The colours of the fixed dark look that was the default before the
    /// toolbar followed the system. Someone who picked "Default" then has
    /// exactly these stored; `migrateStoredDefaultTheme` clears them.
    static let legacyDefaultIconColor = NSColor.white
    static let legacyDefaultBgColor = NSColor(white: 0.12, alpha: 1.0)

    static var isSystemDark: Bool {
        guard let app = NSApp else { return true }
        return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// No toolbar colour has been chosen in Settings: the default theme, which
    /// follows the system appearance.
    static var usesDefaultTheme: Bool {
        let defaults = UserDefaults.standard
        return defaults.data(forKey: "toolbarAccentColor") == nil
            && defaults.data(forKey: "toolbarIconColor") == nil
            && defaults.data(forKey: "toolbarBgColor") == nil
    }

    // User-customizable colors — read from UserDefaults with defaults matching the original look
    static var accentColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarAccentColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultAccentColor
    }
    static var iconColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarIconColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultIconColor
    }
    static var bgColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "toolbarBgColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return color
        }
        return defaultBgColor
    }
    static let cornerRadius: CGFloat = 6

    // Alignment guides — the quiet dashed grey hairline design apps use, plus a
    // faint light halo so it stays readable over dark screenshot content.
    /// One dashed stroke, not two. The earlier version drew a wider translucent
    /// halo underneath for legibility over dark screenshots, but at this weight
    /// the halo reads as a second, blurrier guide running alongside the first.
    /// A single heavier dash in a mid grey holds up on light and dark content
    /// on its own.
    static let snapGuideColor = NSColor(white: 0.52, alpha: 1)
    static let snapGuideDashPattern: [CGFloat] = [6, 5]
    static let snapGuideLineWidth: CGFloat = 2

    /// Save accent color to UserDefaults.
    static func saveAccentColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarAccentColor")
        }
    }

    /// Save icon color to UserDefaults.
    static func saveIconColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarIconColor")
        }
    }

    /// Appearance matching the toolbar background brightness.
    /// Dark background → `.darkAqua`, light background → `.aqua`.
    static var appearance: NSAppearance? {
        NSAppearance(named: isDarkSurface ? .darkAqua : .aqua)
    }

    /// Whether the toolbar surfaces are dark, from the background actually in use.
    static var isDarkSurface: Bool {
        let color = bgColor.usingColorSpace(.deviceRGB) ?? bgColor
        var brightness: CGFloat = 0
        color.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        return brightness <= 0.5
    }

    // MARK: Surface

    /// Corner radius of the toolbar surfaces — strips, options row, size box.
    static let surfaceCornerRadius: CGFloat = 10
    /// The hairline that separates a surface from what is behind it, taken
    /// from the glyph colour so it suits light and dark themes alike.
    static var surfaceBorderColor: NSColor { iconColor.withAlphaComponent(isDarkSurface ? 0.12 : 0.10) }

    /// Clear stored colours that equal the old fixed default, so a user who
    /// had merely picked "Default" gets the default that follows the system.
    static func migrateStoredDefaultTheme(defaults: UserDefaults = .standard) {
        let key = "toolbarDefaultThemeFollowsSystem"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        func stored(_ key: String) -> NSColor? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        }
        guard let accent = stored("toolbarAccentColor"), let icon = stored("toolbarIconColor"),
              let bg = stored("toolbarBgColor"),
              sameColour(accent, defaultAccentColor), sameColour(icon, legacyDefaultIconColor),
              sameColour(bg, legacyDefaultBgColor) else { return }
        defaults.removeObject(forKey: "toolbarAccentColor")
        defaults.removeObject(forKey: "toolbarIconColor")
        defaults.removeObject(forKey: "toolbarBgColor")
    }

    static func sameColour(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let x = a.usingColorSpace(.deviceRGB), let y = b.usingColorSpace(.deviceRGB) else { return false }
        let tolerance = 0.01
        return abs(x.redComponent - y.redComponent) < tolerance
            && abs(x.greenComponent - y.greenComponent) < tolerance
            && abs(x.blueComponent - y.blueComponent) < tolerance
    }

    /// Save background color to UserDefaults.
    static func saveBgColor(_ color: NSColor) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
            UserDefaults.standard.set(data, forKey: "toolbarBgColor")
        }
    }

    /// Reset all colors to defaults.
    static func resetColors() {
        UserDefaults.standard.removeObject(forKey: "toolbarAccentColor")
        UserDefaults.standard.removeObject(forKey: "toolbarIconColor")
        UserDefaults.standard.removeObject(forKey: "toolbarBgColor")
    }

    // Bottom toolbar items (drawing tools + colors + undo/redo + processing actions)
    static func bottomButtons(
        selectedTool: AnnotationTool, selectedColor: NSColor, beautifyEnabled: Bool = false,
        beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false, isRecording: Bool = false,
        effectsActive: Bool = false
    ) -> [ToolbarButton] {
        // Hide the bottom bar entirely while recording
        if isRecording { return [] }

        var buttons: [ToolbarButton] = []

        // Get enabled tools from UserDefaults — migrate: only add tools that are brand-new.
        // Track introduced tools in `knownToolRawValues` so user-disabled tools are never re-enabled.
        let allKnownToolRawValues = AnnotationTool.allCases
            .filter { $0 != .select && $0 != .translateOverlay }
            .map { $0.rawValue }
        var enabledRawValues = UserDefaults.standard.array(forKey: "enabledTools") as? [Int]
        let knownToolRawValues = UserDefaults.standard.array(forKey: "knownToolRawValues") as? [Int]
        let newToolRaws = allKnownToolRawValues.filter { !(knownToolRawValues ?? []).contains($0) }
        if !newToolRaws.isEmpty {
            if enabledRawValues == nil {
                // Fresh install: enable everything.
                enabledRawValues = allKnownToolRawValues
            } else if knownToolRawValues == nil {
                // Upgrading from a version before knownToolRawValues tracking was added.
                // Respect the existing enabledTools as-is; just mark all current tools as known.
            } else {
                // Normal upgrade: new tools introduced — add them enabled by default.
                enabledRawValues = (enabledRawValues! + newToolRaws)
            }
            UserDefaults.standard.set(enabledRawValues, forKey: "enabledTools")
            UserDefaults.standard.set(allKnownToolRawValues, forKey: "knownToolRawValues")
        }

        let tools: [(AnnotationTool, String, String)] = [
            (.pencil, "scribble", L("Pencil (Draw)")),
            (.line, "line.diagonal", L("Line")),
            (.arrow, "arrow.up.right", L("Arrow")),
            (.rectangle, "rectangle", L("Rectangle")),
            (.ellipse, "oval", L("Ellipse")),
            (.marker, {
                if #available(macOS 14.0, *) { return "highlighter" }
                return "paintbrush.pointed.fill"
            }(), L("Marker")),
            (.text, "textformat", L("Text")),
            (.number, "1.circle.fill", L("Number")),
            (.pixelate, "_custom.checkerboard", L("Censor (Pixelate / Blur / Solid)")),
            (.highlight, "sun.max", L("Highlight (Spotlight)")),
            (.loupe, "magnifyingglass", L("Magnify (Loupe)")),
            (.stamp, "face.smiling", L("Stamp / Emoji")),
            (.colorSampler, "eyedropper", L("Color Picker")),
            (.measure, "ruler", L("Measure (px)")),
        ]

        for (tool, symbol, tip) in tools {
            // Skip if disabled
            if let enabledRawValues = enabledRawValues, !enabledRawValues.contains(tool.rawValue) {
                continue
            }
            var btn = ToolbarButton(action: .tool(tool), sfSymbol: symbol, tooltip: tip)
            btn.isSelected = (tool == selectedTool)
            switch tool {
            case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe:
                break  // options shown in the tool options row, not via right-click
            default:
                break
            }
            buttons.append(btn)
        }

        // Color button
        var colorBtn = ToolbarButton(action: .color, sfSymbol: nil, tooltip: L("Color"))
        colorBtn.bgColor = selectedColor
        buttons.append(colorBtn)

        // Undo / Redo
        buttons.append(
            ToolbarButton(
                action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: L("Undo")))
        buttons.append(
            ToolbarButton(
                action: .redo, sfSymbol: "arrow.uturn.forward", tooltip: L("Redo")))

        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        for action in ToolbarCustomAction.bottomToolbarActions {
            guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
            if let button = action.makeToolbarButton(
                beautifyEnabled: beautifyEnabled,
                effectsActive: effectsActive,
                isRecording: isRecording
            ) {
                buttons.append(button)
            }
        }

        return buttons
    }

    // Right toolbar items (output actions + cancel + delay)
    static func rightButtons(
        beautifyEnabled: Bool = false, beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false,
        translateEnabled: Bool = false, isRecording: Bool = false,
        isEditorMode: Bool = false
    ) -> [ToolbarButton] {
        var buttons: [ToolbarButton] = []

        // Recording setup mode — show start button + toggles, then return early
        if isRecording {
            var startBtn = ToolbarButton(
                action: .startRecord, sfSymbol: "record.circle", tooltip: L("Start Recording"))
            startBtn.tintColor = .systemRed
            buttons.append(startBtn)

            // Stop/cancel button to exit recording mode without starting
            buttons.append(
                ToolbarButton(action: .stopRecord, sfSymbol: "xmark", tooltip: L("Cancel Recording")))

            let mouseHighlightOn = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
            var mouseBtn = ToolbarButton(
                action: .mouseHighlight, sfSymbol: "cursorarrow.click.2", tooltip: L("Highlight Mouse Clicks"))
            mouseBtn.isSelected = mouseHighlightOn
            buttons.append(mouseBtn)

            let keystrokesOn = UserDefaults.standard.bool(forKey: "recordKeystroke")
            var keystrokeBtn = ToolbarButton(
                action: .showKeystrokes, sfSymbol: "keyboard", tooltip: L("Show Keystrokes"))
            keystrokeBtn.isSelected = keystrokesOn
            keystrokeBtn.hasContextMenu = true
            buttons.append(keystrokeBtn)

            let audioOn = UserDefaults.standard.bool(forKey: "recordSystemAudio")
            var audioBtn = ToolbarButton(
                action: .systemAudio, sfSymbol: audioOn ? "speaker.wave.2.fill" : "speaker.slash",
                tooltip: L("Record System Audio"))
            audioBtn.isSelected = audioOn
            buttons.append(audioBtn)

            let micOn = UserDefaults.standard.bool(forKey: "recordMicAudio")
            var micBtn = ToolbarButton(
                action: .micAudio, sfSymbol: micOn ? "mic.fill" : "mic.slash", tooltip: L("Record Microphone"))
            micBtn.isSelected = micOn
            micBtn.hasContextMenu = true
            buttons.append(micBtn)

            let webcamOn = UserDefaults.standard.bool(forKey: "recordWebcam")
            let webcamSymbol: String = {
                if #available(macOS 14.0, *) {
                    return webcamOn ? "web.camera.fill" : "web.camera"
                }
                return webcamOn ? "camera.fill" : "camera"
            }()
            var webcamBtn = ToolbarButton(
                action: .webcam, sfSymbol: webcamSymbol, tooltip: L("Webcam Overlay"))
            webcamBtn.isSelected = webcamOn
            webcamBtn.hasContextMenu = true
            buttons.append(webcamBtn)

            // Recording settings gear
            buttons.append(
                ToolbarButton(
                    action: .recordSettings, sfSymbol: "gearshape",
                    tooltip: L("Recording Settings")))

            // Allow moving the selection before starting
            buttons.append(
                ToolbarButton(
                    action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                    tooltip: L("Move Selection")))

            return buttons
        }

        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()

        // Cancel, move-selection, editor — not shown in editor window
        if !isEditorMode {
            buttons.append(
                ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel")))
            buttons.append(
                ToolbarButton(
                    action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                    tooltip: L("Move Selection")))
            buttons.append(
                ToolbarButton(
                    action: .detach, sfSymbol: "arrow.up.forward.app",
                    tooltip: L("Open in Editor Window")))
        }
        // Copy and save are always present
        buttons.append(
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")))
        let saveTooltip: String = {
            switch SaveActionPreference.current {
            case .saveToFolder:
                return "\(L("Save to")) \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
            case .askWhereToSave:
                return L("Ask where to save")
            }
        }()
        var saveBtn = ToolbarButton(
            action: .save, sfSymbol: "square.and.arrow.down.fill",
            tooltip: saveTooltip
        )
        saveBtn.hasContextMenu = true
        buttons.append(saveBtn)

        for action in ToolbarCustomAction.rightToolbarActions {
            guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
            if let button = action.makeToolbarButton(
                translateEnabled: translateEnabled,
                isRecording: isRecording,
                isEditorMode: isEditorMode
            ) {
                buttons.append(button)
            }
        }

        return buttons
    }
}

extension NSView {
    /// Give this view the toolbar surface: theme fill, a hairline edge and a
    /// soft shadow, resolved for the current theme and system appearance.
    /// Call again when the bounds or the appearance change — the shadow path
    /// follows the bounds, and the colours are copied into the layer.
    func applyToolbarSurface(cornerRadius: CGFloat = ToolbarLayout.surfaceCornerRadius) {
        wantsLayer = true
        guard let layer else { return }
        let dark = ToolbarLayout.isDarkSurface
        layer.backgroundColor = ToolbarLayout.bgColor.cgColor
        layer.cornerRadius = cornerRadius
        layer.borderColor = ToolbarLayout.surfaceBorderColor.cgColor
        layer.borderWidth = 1 / max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        layer.masksToBounds = false
        // Strong enough to lift a light bar off a light screenshot or the
        // grey of the dimmed overlay; at 0.14 it disappeared on both.
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = dark ? 0.55 : 0.32
        layer.shadowRadius = dark ? 12 : 11
        layer.shadowOffset = CGSize(width: 0, height: -4)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius,
                                  cornerHeight: cornerRadius, transform: nil)
    }
}

// MARK: - Toolbar tooltips

extension ToolbarLayout {
    /// Tooltips are the inverse of the toolbar — dark with white text beside a
    /// light bar, light with dark text beside a dark one — so they stand out
    /// from both the bar and a screenshot. Taking the bar's own colours made a
    /// white tooltip vanish into a light screenshot.
    static var tooltipBackgroundColor: NSColor {
        isDarkSurface ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.14, alpha: 0.96)
    }
    static var tooltipTextColor: NSColor {
        isDarkSurface ? NSColor(white: 0.10, alpha: 1) : .white
    }
    static let tooltipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let tooltipPadding = NSSize(width: 8, height: 4)
    static let tooltipCornerRadius: CGFloat = 6

    static func tooltipSize(for text: String) -> NSSize {
        let textSize = (text as NSString).size(withAttributes: [.font: tooltipFont])
        return NSSize(width: ceil(textSize.width) + tooltipPadding.width * 2,
                      height: ceil(textSize.height) + tooltipPadding.height * 2)
    }

    /// Draw a tooltip pill filling `rect`, optionally with its own drop shadow
    /// (for tooltips painted straight into a larger view).
    static func drawTooltip(_ text: String, in rect: NSRect, withShadow: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: tooltipCornerRadius, yRadius: tooltipCornerRadius)
        NSGraphicsContext.saveGraphicsState()
        if withShadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
        }
        tooltipBackgroundColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let attrs: [NSAttributedString.Key: Any] = [.font: tooltipFont, .foregroundColor: tooltipTextColor]
        let textSize = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: rect.minX + (rect.width - textSize.width) / 2,
                                            y: rect.minY + (rect.height - textSize.height) / 2),
                                withAttributes: attrs)
    }
}
