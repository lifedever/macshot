import Cocoa

/// Real NSView top bar for the editor window. Pinned to top of container.
/// Contains: pixel dimensions, crop/flip/add-capture buttons, drag-out handle, zoom dropdown.
class EditorTopBarView: NSView {

    weak var overlayView: OverlayView?
    /// Drags the current image into other apps; the editor controller supplies the image.
    let dragHandle = EditorDragHandleView()
    private var sizeLabel: NSTextField!
    private var zoomButton: NSButton!
    private var doneButton: NSButton?
    private var toolButtons: [NSButton] = []
    var onDone: (() -> Void)?
    var onSaveProject: (() -> Void)?

    private let bottomBorder = NSView()

    /// Follow a light/dark switch while the editor is open: the colours are
    /// copied into layers when the bar is built.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyHUDColors()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .minYMargin]  // pin to top, stretch width
        layer?.backgroundColor = ToolbarLayout.bgColor.cgColor

        sizeLabel = makeLabel("")
        sizeLabel.font = UIFonts.monospacedDigit(ofSize: 11, weight: .medium)
        sizeLabel.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.45)

        let cropBtn = makeButton("crop", tooltip: L("Crop"), action: #selector(cropClicked))
        let flipHBtn = makeButton("arrow.left.and.right.righttriangle.left.righttriangle.right", tooltip: L("Flip Horizontal"), action: #selector(flipHClicked))
        let flipVBtn = makeButton("arrow.up.and.down.righttriangle.up.righttriangle.down", tooltip: L("Flip Vertical"), action: #selector(flipVClicked))
        let addCaptureBtn = makeButton("rectangle.badge.plus", tooltip: L("Add Capture"), action: #selector(addCaptureClicked))
        let saveProjectBtn = makeButton("square.and.arrow.down.on.square",
            tooltip: L("Save as Editable Project (⇧⌘S)"), action: #selector(saveProjectClicked))
        toolButtons = [cropBtn, flipHBtn, flipVBtn, addCaptureBtn, saveProjectBtn]

        // Zoom dropdown button
        zoomButton = NSButton()
        zoomButton.bezelStyle = .recessed
        zoomButton.isBordered = false
        zoomButton.title = "100% ▾"
        zoomButton.font = UIFonts.monospacedDigit(ofSize: 11, weight: .medium)
        zoomButton.contentTintColor = ToolbarLayout.iconColor.withAlphaComponent(0.45)
        zoomButton.target = self
        zoomButton.action = #selector(zoomButtonClicked)

        // Bottom border
        let border = bottomBorder
        border.wantsLayer = true
        border.layer?.backgroundColor = ToolbarLayout.surfaceBorderColor.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        // Layout with constraints
        for v: NSView in [sizeLabel, cropBtn, flipHBtn, flipVBtn, addCaptureBtn, saveProjectBtn, dragHandle, zoomButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),

            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            cropBtn.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 16),
            cropBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            cropBtn.widthAnchor.constraint(equalToConstant: 24),
            cropBtn.heightAnchor.constraint(equalToConstant: 22),

            flipHBtn.leadingAnchor.constraint(equalTo: cropBtn.trailingAnchor, constant: 4),
            flipHBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            flipHBtn.widthAnchor.constraint(equalToConstant: 24),
            flipHBtn.heightAnchor.constraint(equalToConstant: 22),

            flipVBtn.leadingAnchor.constraint(equalTo: flipHBtn.trailingAnchor, constant: 4),
            flipVBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            flipVBtn.widthAnchor.constraint(equalToConstant: 24),
            flipVBtn.heightAnchor.constraint(equalToConstant: 22),

            addCaptureBtn.leadingAnchor.constraint(equalTo: flipVBtn.trailingAnchor, constant: 12),
            addCaptureBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            addCaptureBtn.widthAnchor.constraint(equalToConstant: 24),
            addCaptureBtn.heightAnchor.constraint(equalToConstant: 22),

            saveProjectBtn.leadingAnchor.constraint(equalTo: addCaptureBtn.trailingAnchor, constant: 12),
            saveProjectBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            saveProjectBtn.widthAnchor.constraint(equalToConstant: 24),
            saveProjectBtn.heightAnchor.constraint(equalToConstant: 22),

            zoomButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            zoomButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            dragHandle.trailingAnchor.constraint(equalTo: zoomButton.leadingAnchor, constant: -10),
            dragHandle.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 40),
            dragHandle.heightAnchor.constraint(equalToConstant: 22),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        applyHUDColors()
        NotificationCenter.default.addObserver(
            self, selector: #selector(hudColorsChanged),
            name: .toolbarColorsDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func hudColorsChanged() {
        applyHUDColors()
    }

    private func applyHUDColors() {
        layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        bottomBorder.layer?.backgroundColor = ToolbarLayout.surfaceBorderColor.cgColor
        // Optional: an appearance change can arrive before init has built these.
        sizeLabel?.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.45)
        zoomButton?.contentTintColor = ToolbarLayout.iconColor.withAlphaComponent(0.45)
        for button in toolButtons {
            button.contentTintColor = ToolbarLayout.iconColor.withAlphaComponent(0.85)
        }
        doneButton?.contentTintColor = ToolbarLayout.accentColor
        dragHandle.needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .recessed
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        btn.contentTintColor = ToolbarLayout.iconColor.withAlphaComponent(0.85)
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        return btn
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        return label
    }

    func updateSizeLabel(width: Int, height: Int) {
        sizeLabel.stringValue = "\(width) × \(height)"
    }

    func updateZoom(_ magnification: CGFloat) {
        zoomButton.title = "\(Int(magnification * 100))% ▾"
    }

    // MARK: - Zoom dropdown

    @objc private func zoomButtonClicked() {
        if PopoverHelper.toggleClosedIfOpen() { return }
        let currentMag = overlayView?.enclosingScrollView?.magnification ?? 1.0
        let presets: [(title: String, magnification: CGFloat, shortcut: String?)] = [
            ("50%", 0.5, nil), ("100%", 1.0, "⌘0"), ("200%", 2.0, nil),
        ]
        let list = ListPickerView()
        list.items = [
            .init(title: L("Zoom In"), isSelected: false, shortcut: "⌘+"),
            .init(title: L("Zoom Out"), isSelected: false, shortcut: "⌘−"),
            .separator,
            .init(title: L("Fit Canvas"), isSelected: false, shortcut: "⌘1"),
            .separator,
        ] + presets.map { preset in
            .init(title: preset.title, isSelected: abs(currentMag - preset.magnification) < 0.01,
                  shortcut: preset.shortcut)
        }
        list.onSelect = { [weak self] index in
            PopoverHelper.dismiss()
            switch index {
            case 0: self?.zoomInAction()
            case 1: self?.zoomOutAction()
            case 3: self?.fitCanvasAction()
            default:
                let presetIndex = index - 5
                if presets.indices.contains(presetIndex) { self?.applyZoom(presets[presetIndex].magnification) }
            }
        }
        PopoverHelper.showList(list, relativeTo: zoomButton.bounds, of: zoomButton, preferredEdge: .minY)
    }

    private func zoomInAction() {
        guard let sv = overlayView?.enclosingScrollView, let doc = sv.documentView else { return }
        let newMag = min(sv.maxMagnification, sv.magnification * 1.25)
        sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
        updateZoom(newMag)
    }

    private func zoomOutAction() {
        guard let sv = overlayView?.enclosingScrollView, let doc = sv.documentView else { return }
        let newMag = max(sv.minMagnification, sv.magnification / 1.25)
        sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
        updateZoom(newMag)
    }

    private func fitCanvasAction() {
        guard let sv = overlayView?.enclosingScrollView, let doc = sv.documentView else { return }
        let docUnscaledW = doc.frame.width / sv.magnification
        let docUnscaledH = doc.frame.height / sv.magnification
        guard docUnscaledW > 0, docUnscaledH > 0 else { return }
        let clipSize = sv.contentView.bounds.size
        let fitMag = min(clipSize.width / docUnscaledW, clipSize.height / docUnscaledH)
        let clamped = max(sv.minMagnification, min(sv.maxMagnification, fitMag))
        sv.magnification = clamped
        updateZoom(clamped)
    }

    private func applyZoom(_ mag: CGFloat) {
        guard let sv = overlayView?.enclosingScrollView else { return }
        sv.magnification = mag
        updateZoom(mag)
    }

    // MARK: - Top bar actions

    /// Show a "Done" button for committing edits back to history.
    func showDoneButton() {
        guard doneButton == nil else { return }
        let btn = NSButton()
        btn.bezelStyle = .recessed
        btn.isBordered = true
        btn.title = L("Done")
        btn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        btn.contentTintColor = ToolbarLayout.accentColor
        btn.target = self
        btn.action = #selector(doneClicked)
        btn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(btn)
        NSLayoutConstraint.activate([
            btn.trailingAnchor.constraint(equalTo: dragHandle.leadingAnchor, constant: -12),
            btn.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        doneButton = btn
    }

    /// Remove the Done button (used until the user makes an edit).
    func hideDoneButton() {
        doneButton?.removeFromSuperview()
        doneButton = nil
    }

    @objc private func doneClicked() { onDone?() }

    @objc private func cropClicked() {
        overlayView?.toggleCropMode()
    }

    @objc private func flipHClicked() { overlayView?.flipImageHorizontally() }
    @objc private func flipVClicked() { overlayView?.flipImageVertically() }
    @objc private func saveProjectClicked() {
        overlayView?.commitTextFieldIfNeeded()
        onSaveProject?()
    }

    @objc private func addCaptureClicked() { overlayView?.overlayDelegate?.overlayViewDidRequestAddCapture() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
