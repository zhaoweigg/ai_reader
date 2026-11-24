import SwiftUI

extension DiscoverList {
    /// The list Discover is showing, read from the stores that hold each kind of list.
    @MainActor static func current(catalog: ZLibraryStore, bestsellers: BestsellerStore, novels: WebNovelStore, lists: BookListStore) -> DiscoverList {
        if lists.showing { return DiscoverList(lists.source) }
        if novels.showing { return novels.source == .qidian ? .qidian : .weread }
        if bestsellers.showingBestsellers { return bestsellers.source == .nyt ? .nyt : .indie }
        return catalog.feed == .popular ? .popular : .recommended
    }
    /// Puts Discover on this list. Each list's view loads it when it appears; the
    /// Z-Library feeds are loaded by the caller.
    @MainActor func show(catalog: ZLibraryStore, bestsellers: BestsellerStore, novels: WebNovelStore, lists: BookListStore) {
        bestsellers.showingBestsellers = self == .nyt || self == .indie
        novels.showing = self == .qidian || self == .weread
        lists.showing = bookListSource != nil
        switch self {
        case .popular: catalog.show(.popular)
        case .recommended: catalog.show(.recommended)
        case .nyt, .indie:
            bestsellers.source = self == .nyt ? .nyt : .indie; catalog.show(catalog.feed)
        case .qidian, .weread:
            novels.source = self == .qidian ? .qidian : .weread; catalog.show(catalog.feed)
        case .douban, .gutenberg, .apple, .prizes, .openLibrary:
            if let source = bookListSource { lists.source = source }
            catalog.show(catalog.feed)
        }
    }
}

/// One chip per list Discover shows, then the button that opens the Discover lists sheet.
struct DiscoverListChips: View {
    @Environment(\.leafTheme) private var theme
    let lists: [DiscoverList]
    let selection: DiscoverList
    let select: (DiscoverList) -> Void
    let edit: () -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(lists) { list in
                        let selected = list == selection
                        Button { select(list) } label: {
                            Text(list.title).font(.subheadline.weight(selected ? .semibold : .regular)).lineLimit(1)
                                .padding(.horizontal, 14).frame(minHeight: 36)
                                .foregroundStyle(selected ? theme.onAccent : Color.primary)
                                .background(selected ? theme.accent : theme.surface, in: .capsule)
                                .contentShape(.capsule)
                        }.buttonStyle(.plain).id(list)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("discoverList-\(list.rawValue)")
                    }
                    Button(action: edit) {
                        Image(systemName: "slider.horizontal.3").font(.subheadline.weight(.medium)).foregroundStyle(theme.accent)
                            .frame(width: 44, height: 36).background(theme.surface, in: .capsule).contentShape(.capsule)
                    }.buttonStyle(.plain).accessibilityLabel("Discover lists").accessibilityIdentifier("editDiscoverLists")
                }.padding(.vertical, 2)
            }
            .accessibilityIdentifier("discoverListChips")
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, value in withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(value, anchor: .center) } }
        }
    }
}

/// Choose which lists Discover shows and their order. The choice syncs with the reader's other devices.
struct DiscoverListsEditor: View {
    @EnvironmentObject private var arrangement: DiscoverListsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.leafTheme) private var theme
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(arrangement.shown) { list in row(list) }
                        .onMove { arrangement.move(from: $0, to: $1) }
                } header: { Text("Shown") } footer: {
                    Text("Drag to change the order of the chips. At least one list stays on. Your choice syncs with your other devices.")
                }
                if !arrangement.hidden.isEmpty {
                    Section("Hidden") { ForEach(arrangement.hidden) { list in row(list) } }
                }
                Section {
                    Button("Restore the original lists") { arrangement.restoreInitialLists() }.accessibilityIdentifier("restoreDiscoverLists")
                }
            }
            .listRowBackground(theme.surface)
            .leafFormStyle()
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Discover lists").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("doneDiscoverLists") } }
        }
    }
    private func row(_ list: DiscoverList) -> some View {
        let shown = arrangement.isShown(list)
        return Toggle(isOn: Binding(get: { shown }, set: { arrangement.setShown(list, $0) })) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.name)
                    Text(list.detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: list.symbol).foregroundStyle(theme.accent) }
        }
        .disabled(shown && arrangement.shown.count == 1)
        .accessibilityIdentifier("discoverListToggle-\(list.rawValue)")
    }
}
