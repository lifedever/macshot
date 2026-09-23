import Cocoa
import UniformTypeIdentifiers

extension OverlayView {

    #if !OFFLINE
    func showUploadConfirmPopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        if PopoverHelper.toggleClosedIfOpen() { return }

        let current = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 32))

        let toggle = NSButton(checkboxWithTitle: L("Confirm before upload"), target: nil, action: nil)
        toggle.state = current ? .on : .off
        toggle.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        toggle.sizeToFit()
        toggle.frame.origin = NSPoint(x: 10, y: (32 - toggle.frame.height) / 2)
        toggle.target = toggle  // self-target via associated handler
        container.addSubview(toggle)

        class ToggleHandler: NSObject {
            @objc func toggled(_ sender: NSButton) {
                UserDefaults.standard.set(sender.state == .on, forKey: "uploadConfirmEnabled")
            }
        }
        let handler = ToggleHandler()
        toggle.target = handler
        toggle.action = #selector(ToggleHandler.toggled(_:))
        objc_setAssociatedObject(toggle, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        let size = NSSize(width: max(180, toggle.frame.width + 20), height: 32)
        container.frame.size = size

        if let anchor = anchorView {
            PopoverHelper.show(
                container, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                container, size: size, at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY),
                in: self, preferredEdge: .maxX)
        }
    }
    #endif

    func showRedactTypePopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        let types = AutoRedactor.redactTypeNames
        let picker = ListPickerView()
        picker.items = types.map { item in
            .init(
                title: item.label,
                isSelected: UserDefaults.standard.object(forKey: item.key) as? Bool ?? true)
        }
        picker.onSelect = { [weak self] idx in
            let key = types[idx].key
            let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
            UserDefaults.standard.set(!current, forKey: key)
            picker.items = types.map { item in
                .init(
                    title: item.label,
                    isSelected: UserDefaults.standard.object(forKey: item.key) as? Bool ?? true)
            }
            self?.needsDisplay = true
        }
        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: size, at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY),
                in: self, preferredEdge: .maxX)
        }
    }

    func showTranslatePopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        let languages = TranslationService.availableLanguages
        let currentCode = TranslationService.targetLanguage

        let showPopover: ([String: Bool]?) -> Void = { [weak self] appleAvailability in
            guard let self = self else { return }
            // When Apple Translation is active, only show installed languages
            let filteredLanguages: [(code: String, name: String)]
            if let avail = appleAvailability {
                filteredLanguages = languages.filter { avail[$0.code] == true }
            } else {
                filteredLanguages = languages
            }
            let picker = ListPickerView()
            let pickerW: CGFloat = 220
            picker.frame.size.width = pickerW
            picker.items = filteredLanguages.map { lang in
                return .init(title: lang.name, isSelected: lang.code == currentCode,
                             isEnabled: true, subtitle: nil)
            }
            picker.onSelect = { [weak self] idx in
                let newCode = filteredLanguages[idx].code
                TranslationService.targetLanguage = newCode
                PopoverHelper.dismiss()
                if let self = self, self.translateEnabled {
                    self.performTranslate(targetLang: newCode)
                }
                self?.needsDisplay = true
            }

            // As wide as the longest language name needs, never narrower
            // than before.
            let listW = max(pickerW, picker.preferredSize.width)
            picker.frame.size.width = listW
            let contentH = picker.frame.height
            let maxH: CGFloat = 350
            let popoverSize = NSSize(width: listW, height: min(maxH, contentH))

            let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: popoverSize))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = false
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.documentView = picker

            if let anchor = anchorView {
                PopoverHelper.show(
                    scrollView, size: popoverSize, relativeTo: anchor.bounds, of: anchor,
                    preferredEdge: .maxY)
            } else {
                PopoverHelper.showAtPoint(
                    scrollView, size: popoverSize,
                    at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY),
                    in: self, preferredEdge: .maxX)
            }

            DispatchQueue.main.async {
                picker.scrollToSelected()
            }
        }

        // If Apple Translation is selected, check which languages are installed
        if #available(macOS 15.0, *), TranslationService.provider == .apple {
            TranslationService.checkAppleLanguageAvailability { availability in
                showPopover(availability)
            }
        } else {
            showPopover(nil)
        }
    }

    func showBeautifyGradientPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        let picker = GradientPickerView(selectedIndex: beautifyStyleIndex)
        picker.onSelect = { [weak self] idx in
            guard let self = self else { return }
            self.beautifyStyleIndex = idx
            UserDefaults.standard.set(idx, forKey: "beautifyStyleIndex")
            if idx >= 0 {
                // Gradient selected — clear custom background
                self.customBeautifyBackground = nil
            } else {
                // Custom image selected — load from storage
                self.loadCustomBeautifyBackground()
            }
            self.cachedCompositedImage = nil
            self.needsDisplay = true
            self.updateBeautifySwatch(styleIndex: idx)
            self.onContentChanged?()
            // Rebuild options row so blur slider appears/disappears
            self.rebuildToolbarLayout()
        }
        picker.onCustomImage = { [weak self] in
            PopoverHelper.dismiss()
            self?.pickCustomBeautifyBackground()
        }
        picker.onUseWallpaper = { [weak self] in
            PopoverHelper.dismiss()
            self?.useDesktopWallpaperAsBeautifyBackground()
        }
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: picker.preferredSize, relativeTo: anchor.bounds, of: anchor,
                preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: picker.preferredSize,
                at: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
                in: self, preferredEdge: .minY)
        }
    }

    func pickCustomBeautifyBackground() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        // Lower overlay window level temporarily so the open panel is interactive
        let savedLevel = window?.level
        window?.level = .normal
        panel.beginSheetModal(for: window!) { [weak self] response in
            self?.window?.level = savedLevel ?? .normal
            guard let self = self, response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            // Store image data (PNG) in UserDefaults for persistence
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                UserDefaults.standard.set(pngData, forKey: "beautifyCustomBgImageData")
            }
            self.customBeautifyBackground = image
            self.prepareBeautifyBackgroundCache()
            self.beautifyStyleIndex = -1
            UserDefaults.standard.set(-1, forKey: "beautifyStyleIndex")
            self.cachedCompositedImage = nil
            self.needsDisplay = true
            self.updateBeautifySwatch(styleIndex: -1)
            self.rebuildToolbarLayout()
        }
    }

    /// Capture the current desktop wallpaper and use it as the beautify background.
    /// Feeds the existing custom-background pipeline, so the blur slider, persistence and
    /// the picker's thumbnail all work without special-casing wallpapers.
    func useDesktopWallpaperAsBeautifyBackground() {
        guard #available(macOS 14.0, *) else { return }
        let screen = window?.screen ?? NSScreen.main
        guard let screen else { return }

        Task { @MainActor [weak self] in
            guard let image = await DesktopWallpaper.capture(for: screen) else {
                // Leave whatever background is configured in place — replacing it with a
                // blank one would silently look like the wallpaper is a black image.
                return
            }
            guard let self else { return }

            // A wallpaper is a full-resolution screen image; stored raw it bloats the
            // preferences plist by several megabytes. It only ever renders behind a
            // capture, often blurred, so downsampled JPEG is indistinguishable here.
            if let data = Self.compactBackgroundData(from: image) {
                UserDefaults.standard.set(data, forKey: "beautifyCustomBgImageData")
            }
            self.customBeautifyBackground = image
            self.prepareBeautifyBackgroundCache()
            self.beautifyStyleIndex = -1
            UserDefaults.standard.set(-1, forKey: "beautifyStyleIndex")
            self.cachedCompositedImage = nil
            self.needsDisplay = true
            self.updateBeautifySwatch(styleIndex: -1)
            self.rebuildToolbarLayout()
            self.onContentChanged?()
        }
    }

    /// Downsample to at most `maxEdge` on the long side and encode as JPEG.
    /// Returns nil if the image can't be rasterized, in which case the caller keeps the
    /// in-memory image and simply doesn't persist it.
    private static func compactBackgroundData(from image: NSImage, maxEdge: CGFloat = 1920) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(w, h))
        let target = NSSize(width: round(w * scale), height: round(h * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = target

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero, operation: .copy, fraction: 1.0)
        ctx.flushGraphics()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    func loadCustomBeautifyBackground() {
        guard let data = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData"),
              let image = NSImage(data: data) else { return }
        customBeautifyBackground = image
        prepareBeautifyBackgroundCache()
    }

    func showEmojiPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        let picker = EmojiPickerView()
        picker.onSelectEmoji = { [weak self] emoji in
            self?.currentStampImage = StampEmojis.renderEmoji(emoji)
            self?.currentStampEmoji = emoji
            self?.needsDisplay = true
        }
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: picker.preferredSize, relativeTo: anchor.bounds, of: anchor,
                preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: picker.preferredSize,
                at: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
                in: self, preferredEdge: .minY)
        }
    }

    // MARK: - Recording Settings Popover

    func showRecordingSettingsPopover(anchorView: NSView?) {
        if PopoverHelper.toggleClosedIfOpen() { return }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        var y: CGFloat = 8
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let labelColor = NSColor.secondaryLabelColor

        // Rows are stacked from the bottom up (the container is not flipped).
        func addRow(label: String, control: NSView, controlWidth: CGFloat = 140) {
            let lbl = NSTextField(labelWithString: label)
            lbl.font = labelFont
            lbl.textColor = labelColor
            lbl.frame = NSRect(x: 10, y: y + 2, width: 76, height: 18)
            container.addSubview(lbl)
            control.frame = NSRect(x: 88, y: y, width: controlWidth, height: 22)
            container.addSubview(control)
            y += 28
        }

        // Webcam settings (only when webcam is enabled) sit under the list.
        if UserDefaults.standard.bool(forKey: "recordWebcam") {
            // Position
            let posSeg = NSSegmentedControl(labels: ["↙", "↘", "↖", "↗"], trackingMode: .selectOne, target: nil, action: nil)
            let currentPos = UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight"
            switch currentPos {
            case "bottomLeft": posSeg.selectedSegment = 0
            case "bottomRight": posSeg.selectedSegment = 1
            case "topLeft": posSeg.selectedSegment = 2
            case "topRight": posSeg.selectedSegment = 3
            default: posSeg.selectedSegment = 1
            }

            class PosHandler: NSObject {
                weak var overlayView: OverlayView?
                init(overlayView: OverlayView?) { self.overlayView = overlayView; super.init() }
                @objc func changed(_ sender: NSSegmentedControl) {
                    let values = ["bottomLeft", "bottomRight", "topLeft", "topRight"]
                    UserDefaults.standard.set(values[sender.selectedSegment], forKey: "webcamPosition")
                    overlayView?.updateWebcamSetupPreview()
                }
            }
            let posHandler = PosHandler(overlayView: self)
            posSeg.target = posHandler
            posSeg.action = #selector(PosHandler.changed(_:))
            objc_setAssociatedObject(posSeg, "handler", posHandler, .OBJC_ASSOCIATION_RETAIN)

            // Size — continuous and live so it scales well on high-resolution displays.
            let sizeSlider = NSSlider(
                value: Double(WebcamSize.savedPoints),
                minValue: Double(WebcamSize.minPoints),
                maxValue: Double(WebcamSize.maxPoints), target: nil, action: nil)
            sizeSlider.isContinuous = true

            class SizeHandler: NSObject {
                weak var overlayView: OverlayView?
                init(overlayView: OverlayView?) {
                    self.overlayView = overlayView
                    super.init()
                }
                @objc func changed(_ sender: NSSlider) {
                    WebcamSize.save(points: CGFloat(sender.doubleValue))
                    sender.doubleValue = Double(WebcamSize.savedPoints)
                    overlayView?.updateWebcamSetupPreview()
                }
            }
            let sizeHandler = SizeHandler(overlayView: self)
            sizeSlider.target = sizeHandler
            sizeSlider.action = #selector(SizeHandler.changed(_:))
            objc_setAssociatedObject(sizeSlider, "handler", sizeHandler, .OBJC_ASSOCIATION_RETAIN)

            // Shape
            let shapeSeg = NSSegmentedControl(labels: ["●", "▢"], trackingMode: .selectOne, target: nil, action: nil)
            let currentShape = UserDefaults.standard.string(forKey: "webcamShape") ?? "circle"
            shapeSeg.selectedSegment = currentShape == "roundedRect" ? 1 : 0

            class ShapeHandler: NSObject {
                weak var overlayView: OverlayView?
                init(overlayView: OverlayView?) { self.overlayView = overlayView; super.init() }
                @objc func changed(_ sender: NSSegmentedControl) {
                    let values = ["circle", "roundedRect"]
                    UserDefaults.standard.set(values[sender.selectedSegment], forKey: "webcamShape")
                    overlayView?.updateWebcamSetupPreview()
                }
            }
            let shapeHandler = ShapeHandler(overlayView: self)
            shapeSeg.target = shapeHandler
            shapeSeg.action = #selector(ShapeHandler.changed(_:))
            objc_setAssociatedObject(shapeSeg, "handler", shapeHandler, .OBJC_ASSOCIATION_RETAIN)

            addRow(label: L("Cam pos:"), control: posSeg)
            addRow(label: L("Cam size:"), control: sizeSlider)
            addRow(label: L("Cam shape:"), control: shapeSeg)

            let sep = NSBox()
            sep.boxType = .separator
            sep.frame = NSRect(x: 10, y: y + 2, width: 220, height: 1)
            container.addSubview(sep)
            y += 6
        }

        // Frame rate, what happens when the recording stops, the countdown and
        // the HUD, as one checkmark list in the toolbar's style. These were
        // pop-up buttons whose native menus sat oddly beside the toolbar. The
        // choices apply to this session only (see the session overrides).
        let fpsOptions = [15, 30, 60, 120]
        let onStopOptions = ["editor", "finder", "clipboard"]
        let onStopTitles = [L("Open editor"), L("Show in Finder"), L("Copy to clipboard")]
        let delayOptions = [0, 3, 5, 10, 30]
        let delayHeader = L("Delay:").trimmingCharacters(in: CharacterSet(charactersIn: ":： "))

        let list = ListPickerView()
        let fpsStart = 1
        let onStopStart = fpsStart + fpsOptions.count + 1
        let delayStart = onStopStart + onStopOptions.count + 1
        let hideHUDIndex = delayStart + delayOptions.count + 1
        func currentItems() -> [ListPickerView.Item] {
            let savedFPS = UserDefaults.standard.integer(forKey: "recordingFPS")
            let fps = sessionRecordingFPS ?? (savedFPS > 0 ? savedFPS : 30)
            let fpsChoice = fpsOptions.first { fps <= $0 } ?? fpsOptions[fpsOptions.count - 1]
            let onStop = sessionRecordingOnStop ?? UserDefaults.standard.string(forKey: "recordingOnStop") ?? "editor"
            let delay = sessionRecordingDelay ?? UserDefaults.standard.integer(forKey: "captureDelaySeconds")
            let hideHUD = sessionHideRecordingHUD ?? UserDefaults.standard.bool(forKey: "hideRecordingHUD")
            var items: [ListPickerView.Item] = [.header(L("Frame rate"))]
            items += fpsOptions.map { .init(title: "\($0) fps", isSelected: $0 == fpsChoice) }
            items.append(.header(L("When done")))
            items += zip(onStopOptions, onStopTitles).map { .init(title: $0.1, isSelected: $0.0 == onStop) }
            items.append(.header(delayHeader))
            items += delayOptions.map {
                .init(title: $0 == 0 ? L("None") : String(format: L("%d seconds"), $0), isSelected: $0 == delay)
            }
            items.append(.separator)
            items.append(.init(title: L("Hide controls"), isSelected: hideHUD))
            return items
        }
        list.items = currentItems()
        list.onSelect = { [weak self, weak list] index in
            guard let self else { return }
            switch index {
            case fpsStart..<(fpsStart + fpsOptions.count):
                self.sessionRecordingFPS = fpsOptions[index - fpsStart]
            case onStopStart..<(onStopStart + onStopOptions.count):
                self.sessionRecordingOnStop = onStopOptions[index - onStopStart]
            case delayStart..<(delayStart + delayOptions.count):
                self.sessionRecordingDelay = delayOptions[index - delayStart]
            case hideHUDIndex:
                let hidden = self.sessionHideRecordingHUD ?? UserDefaults.standard.bool(forKey: "hideRecordingHUD")
                self.sessionHideRecordingHUD = !hidden
            default:
                return
            }
            // Stay open, like a settings panel, and move the checkmark.
            list?.items = currentItems()
        }

        let listSize = list.preferredSize
        let width = max(240, listSize.width)
        list.frame = NSRect(x: 0, y: y, width: width, height: listSize.height)
        container.addSubview(list)
        y += listSize.height

        let size = NSSize(width: width, height: y + 4)
        container.frame.size = size

        if let anchor = anchorView {
            PopoverHelper.show(
                container, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                container, size: size,
                at: NSPoint(x: bounds.midX, y: bounds.midY),
                in: self, preferredEdge: .maxY)
        }
    }

    // MARK: - Auto-redact & Translate actions

    func performAutoRedact() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? screenshotImage : nil
        AutoRedactor.redactPII(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func performRedactAllText() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? screenshotImage : nil
        AutoRedactor.redactAllText(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func performRedactFaces() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? screenshotImage : nil
        AutoRedactor.redactFaces(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func performRedactPeople() {
        guard state == .selected, let screenshot = screenshotImage else { return }
        let tool: AnnotationTool = currentTool == .pixelate ? .pixelate : .rectangle
        let sourceImg = tool == .pixelate ? screenshotImage : nil
        AutoRedactor.redactPeople(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            redactTool: tool, color: currentColor, sourceImage: sourceImg,
            sourceImageBounds: captureDrawRect
        ) { [weak self] anns in
            guard let self = self, !anns.isEmpty else { return }
            self.annotations.append(contentsOf: anns)
            self.undoStack.append(contentsOf: anns.map { .added($0) })
            self.redoStack.removeAll()
            self.cachedCompositedImage = nil
            self.needsDisplay = true
        }
    }

    func showEffectsPopover(anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        let picker = EffectsPickerView(config: effectsConfig)
        picker.onConfigChanged = { [weak self] config in
            guard let self = self else { return }
            self.effectsPreset = config.preset
            self.effectsBrightness = config.brightness
            self.effectsContrast = config.contrast
            self.effectsSaturation = config.saturation
            self.effectsSharpness = config.sharpness
            UserDefaults.standard.set(config.preset.rawValue, forKey: "effectsPreset")
            UserDefaults.standard.set(Double(config.brightness), forKey: "effectsBrightness")
            UserDefaults.standard.set(Double(config.contrast), forKey: "effectsContrast")
            UserDefaults.standard.set(Double(config.saturation), forKey: "effectsSaturation")
            UserDefaults.standard.set(Double(config.sharpness), forKey: "effectsSharpness")
            self.cachedCompositedImage = nil
            self.cachedEffectsScreenshot = nil
            self.rebuildToolbarLayout()
            self.needsDisplay = true
            self.onContentChanged?()
        }
        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(
                picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(
                picker, size: size,
                at: NSPoint(x: anchorRect.midX, y: anchorRect.midY),
                in: self, preferredEdge: .maxY)
        }
    }

    func performTranslate(targetLang: String) {
        guard state == .selected, let screenshot = screenshotImage else { return }
        annotations.removeAll { $0.tool == .translateOverlay }
        isTranslating = true
        needsDisplay = true

        TranslateOverlay.translate(
            screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect,
            targetLang: targetLang,
            onError: { [weak self] msg in
                self?.isTranslating = false
                self?.showOverlayError(msg)
                self?.needsDisplay = true
            },
            completion: { [weak self] anns in
                guard let self = self else { return }
                self.isTranslating = false
                self.annotations.removeAll { $0.tool == .translateOverlay }
                self.annotations.append(contentsOf: anns)
                self.undoStack.append(contentsOf: anns.map { .added($0) })
                self.redoStack.removeAll()
                self.needsDisplay = true
            }
        )
    }
}
