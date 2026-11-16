import QuickLook
import SwiftUI

/// The library window: a sidebar of kinds and dates, the items as icons or a
/// list, and an inspector for the selection — the Finder's layout, so it
/// takes the system's chrome (Liquid Glass on macOS 26 and later).
struct LibraryView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            // The toolbar, search and inspector belong to the content column.
            // On the split view as a whole they went to the trailing-most
            // column — the inspector — which is too narrow for them, and the
            // buttons collapsed into an overflow menu.
            LibraryContent(model: model)
                .modifier(LibraryChrome(model: model))
        }
        .quickLookPreview($model.quickLookURL, in: model.selectedItems.map(\.fileURL))
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        List(selection: $model.section) {
            Section(L("Library")) {
                ForEach(LibrarySection.kinds) { row($0) }
            }
            Section(L("Date Created")) {
                ForEach(LibrarySection.dates) { row($0) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ section: LibrarySection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(model.count(in: section))
            .tag(section)
    }
}

// MARK: - Toolbar, search, inspector

private struct LibraryChrome: ViewModifier {
    @ObservedObject var model: LibraryModel

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .searchable(text: $model.search, placement: .toolbar)
                .toolbar { toolbarItems }
                .inspector(isPresented: $model.inspectorPresented) {
                    LibraryInspector(model: model)
                        .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
                }
        } else {
            // Before macOS 14 a hosted window doesn't take SwiftUI's toolbar.
            content.safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 12) {
                    LibraryViewModePicker(model: model)
                    LibrarySortMenu(model: model)
                    Spacer()
                    TextField(L("Search"), text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    /// `.automatic` places these at the content column's trailing edge, where
    /// the Finder keeps them; `.primaryAction` is the leading edge on macOS.
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            LibraryViewModePicker(model: model)
            LibrarySortMenu(model: model)
            ShareLink(items: model.selectedItems.map(\.fileURL)) {
                Label(L("Share"), systemImage: "square.and.arrow.up")
            }
            .disabled(model.selection.isEmpty)
            Button {
                model.delete(model.selectedItems)
            } label: {
                Label(L("Delete"), systemImage: "trash")
            }
            .disabled(model.selection.isEmpty)
            Button {
                model.wantsInspector.toggle()
            } label: {
                Label(L("Info"), systemImage: "info.circle")
            }
            // With nothing selected the inspector stays closed, so the
            // button would do nothing visible.
            .disabled(model.selection.isEmpty)
        }
    }
}

private struct LibraryViewModePicker: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        Picker(L("View"), selection: $model.viewMode) {
            Label(L("Icons"), systemImage: "square.grid.2x2").tag(LibraryViewMode.grid)
            Label(L("List"), systemImage: "list.bullet").tag(LibraryViewMode.list)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .fixedSize()
    }
}

private struct LibrarySortMenu: View {
    @ObservedObject var model: LibraryModel

    private enum Field: Hashable { case created, name, size, kind }

    private var field: Binding<Field> {
        Binding(get: {
            switch model.sortOrder.first?.keyPath {
            case \LibraryItem.name: return .name
            case \LibraryItem.fileSize: return .size
            case \LibraryItem.kindTitle: return .kind
            default: return .created
            }
        }, set: { field in
            switch field {
            case .created: model.sortOrder = [KeyPathComparator(\LibraryItem.createdAt, order: .reverse)]
            case .name: model.sortOrder = [KeyPathComparator(\LibraryItem.name)]
            case .size: model.sortOrder = [KeyPathComparator(\LibraryItem.fileSize, order: .reverse)]
            case .kind: model.sortOrder = [KeyPathComparator(\LibraryItem.kindTitle)]
            }
        })
    }

    var body: some View {
        Menu {
            Picker(L("Sort By"), selection: field) {
                Text(L("Date Created")).tag(Field.created)
                Text(L("Name")).tag(Field.name)
                Text(L("Size")).tag(Field.size)
                Text(L("Kind")).tag(Field.kind)
            }
            .pickerStyle(.inline)
        } label: {
            Label(L("Sort By"), systemImage: "arrow.up.arrow.down")
        }
        .fixedSize()
    }
}

// MARK: - Content

private struct LibraryContent: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        let items = model.visibleItems
        Group {
            if items.isEmpty {
                if #available(macOS 14.0, *) {
                    ContentUnavailableView(L("No Items"), systemImage: "tray")
                } else {
                    Text(L("No Items"))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.viewMode == .grid {
                LibraryGrid(model: model, items: items)
            } else {
                LibraryTable(model: model, items: items)
            }
        }
        .navigationTitle((model.section ?? .all).title)
        .onDeleteCommand { model.delete(model.selectedItems) }
    }
}

/// Space previews the selection, as in the Finder. The grid has to take
/// focus for the key to reach it (without drawing a ring round the whole
/// grid); the table takes focus on its own.
private struct QuickLookOnSpace: ViewModifier {
    @ObservedObject var model: LibraryModel
    var makesFocusable = false

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .modifier(Focusable(enabled: makesFocusable))
                .onKeyPress(.space) {
                    guard let first = model.selectedItems.first else { return .ignored }
                    model.quickLookURL = model.quickLookURL == nil ? first.fileURL : nil
                    return .handled
                }
        } else {
            content
        }
    }

    @available(macOS 14.0, *)
    private struct Focusable: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled {
                content.focusable().focusEffectDisabled()
            } else {
                content
            }
        }
    }
}

// MARK: Icons

private struct LibraryGrid: View {
    @ObservedObject var model: LibraryModel
    let items: [LibraryItem]
    @State private var anchorID: String?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(items) { item in
                    LibraryTile(model: model, item: item, isSelected: model.selection.contains(item.id))
                        .onTapGesture(count: 2) { model.open(item) }
                        .simultaneousGesture(TapGesture().onEnded { select(item) })
                        .contextMenu { LibraryItemMenu(model: model, items: targets(for: item)) }
                        .onDrag { NSItemProvider(contentsOf: item.fileURL) ?? NSItemProvider() }
                }
            }
            .padding(20)
        }
        .modifier(QuickLookOnSpace(model: model, makesFocusable: true))
    }

    /// The menu acts on the selection when the clicked item is part of it,
    /// otherwise on the clicked item alone, as in the Finder.
    private func targets(for item: LibraryItem) -> [LibraryItem] {
        model.selection.contains(item.id) ? model.selectedItems : [item]
    }

    private func select(_ item: LibraryItem) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
            anchorID = item.id
        } else if flags.contains(.shift), let anchorID,
                  let from = items.firstIndex(where: { $0.id == anchorID }),
                  let to = items.firstIndex(where: { $0.id == item.id }) {
            model.selection = Set(items[min(from, to)...max(from, to)].map(\.id))
        } else {
            model.selection = [item.id]
            anchorID = item.id
        }
    }
}

private struct LibraryTile: View {
    @ObservedObject var model: LibraryModel
    let item: LibraryItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
                if let image = model.thumbnails[item.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .padding(6)
                } else {
                    Image(systemName: item.kind == .recording ? "video" : "photo")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if item.kind == .recording {
                    Label(model.detailText(for: item), systemImage: "video.fill")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(12)
                }
            }
            .frame(height: 128)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2.5 : 0)
            )

            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Text(item.kind == .recording ? item.sizeText : item.dimensionsText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onAppear { model.loadThumbnail(for: item) }
    }
}

// MARK: List

private struct LibraryTable: View {
    @ObservedObject var model: LibraryModel
    let items: [LibraryItem]

    var body: some View {
        Table(items, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn(L("Name"), value: \.name) { item in
                HStack(spacing: 8) {
                    Group {
                        if let image = model.thumbnails[item.id] {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: item.kind == .recording ? "video" : "photo")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 28, height: 20)
                    Text(item.name).lineLimit(1)
                }
                .onAppear { model.loadThumbnail(for: item) }
            }
            .width(min: 180, ideal: 300)
            TableColumn(L("Kind"), value: \.kindTitle)
                .width(min: 70, ideal: 90)
            TableColumn(L("Dimensions")) { item in
                Text(item.kind == .screenshot ? item.dimensionsText : "—").monospacedDigit()
            }
            .width(min: 80, ideal: 100)
            TableColumn(L("Duration")) { item in
                Text(item.kind == .recording ? model.detailText(for: item) : "—").monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn(L("Size"), value: \.fileSize) { item in
                Text(item.sizeText).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn(L("Date Created"), value: \.createdAt) { item in
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 120, ideal: 160)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            LibraryItemMenu(model: model, items: model.items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            model.items.filter { ids.contains($0.id) }.forEach(model.open)
        }
        .modifier(QuickLookOnSpace(model: model))
    }
}

// MARK: Menu

private struct LibraryItemMenu: View {
    @ObservedObject var model: LibraryModel
    let items: [LibraryItem]

    var body: some View {
        if let first = items.first {
            Button(L("Open in Editor")) { items.forEach(model.open) }
            Button(L("Quick Look")) { model.quickLook(first) }
            Divider()
            if items.count == 1 {
                Button(L("Copy")) { model.copy(first) }
                Button(L("Save As...")) { model.saveCopy(first) }
            }
            Button(L("Show in Finder")) { model.showInFinder(items) }
            ShareLink(items: items.map(\.fileURL)) { Text(L("Share")) }
            Divider()
            Button(items.allSatisfy { $0.kind == .recording } ? L("Move to Trash") : L("Delete"), role: .destructive) {
                model.delete(items)
            }
        }
    }
}

// MARK: - Inspector

private struct LibraryInspector: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        let selected = model.selectedItems
        Group {
            if selected.count == 1, let item = selected.first {
                details(item)
            } else {
                Text(selected.isEmpty ? L("No Selection") : String(format: L("%d Items Selected"), selected.count))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func details(_ item: LibraryItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if let image = model.thumbnails[item.id] {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.08))
                            .frame(height: 140)
                    }
                }
                .frame(maxWidth: .infinity)
                .onAppear { model.loadThumbnail(for: item) }

                Text(item.name)
                    .font(.headline)
                    .textSelection(.enabled)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    row(L("Kind"), item.kindTitle)
                    if item.kind == .screenshot {
                        row(L("Dimensions"), item.dimensionsText)
                    } else {
                        row(L("Duration"), model.detailText(for: item))
                    }
                    row(L("Size"), item.sizeText)
                    row(L("Created"), item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let edited = item.editedAt {
                        row(L("Edited"), edited.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let origin = item.origin, !origin.isEmpty {
                        row(L("Source"), origin)
                    }
                    row(L("Location"), (item.fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                }
                .font(.callout)

                HStack {
                    Button(L("Open in Editor")) { model.open(item) }
                        .keyboardShortcut(.defaultAction)
                    Button(L("Show in Finder")) { model.showInFinder([item]) }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
