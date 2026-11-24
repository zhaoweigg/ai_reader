import SwiftUI

struct WebNovelCover: View {
    @Environment(\.leafTheme) private var theme
    let novel: WebNovel
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(theme.surface)
            #if DEBUG
            if UITesting.flag(.webNovelsMock) { placeholder } else { remote }
            #else
            remote
            #endif
        }.aspectRatio(3 / 4, contentMode: .fit).clipShape(.rect(cornerRadius: 4))
            .accessibilityElement(children: .ignore).accessibilityLabel(novel.title + " cover")
    }
    private var remote: some View {
        AsyncImage(url: novel.coverURL) { phase in
            if let image = phase.image { image.resizable().scaledToFit() } else { placeholder }
        }
    }
    private var placeholder: some View { Image(systemName: "book.closed").font(.title3).foregroundStyle(theme.accent) }
}

/// Discover's 中文 section: one 起点 or 微信读书 chart at a time, a row per book with its synopsis.
struct WebNovelCharts: View {
    @EnvironmentObject private var novels: WebNovelStore
    @EnvironmentObject private var matching: BestsellerMatching
    @EnvironmentObject private var catalog: ZLibraryStore
    @Environment(\.leafTheme) private var theme
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("中文榜单").font(.system(size: 32, design: .serif)).accessibilityIdentifier("webNovelsHeading")
                Spacer()
                Button("Refresh chart", systemImage: "arrow.clockwise") { Task { await novels.load(force: true) } }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(novels.isLoading)
                    .accessibilityIdentifier("webNovelsRefresh")
            }
            Picker("Site", selection: $novels.source) {
                ForEach(WebNovelSource.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("webNovelSourcePicker")
            Picker("Chart", selection: $novels.chart) {
                ForEach(novels.source.charts) { Text($0.shortTitle).tag($0) }
            }.pickerStyle(.segmented).id(novels.source).accessibilityIdentifier("webNovelChartPicker")
            HStack(spacing: 12) {
                if novels.source == .qidian { categoryMenu }
                else { Text(novels.chart == .top ? "TOP 200" : novels.chart.title).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if let list = novels.selected {
                    Text(list.published.isEmpty ? "Retrieved \(list.fetchedAt.formatted(date: .abbreviated, time: .omitted))" : list.published)
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("webNovelListDate")
                }
            }.frame(minHeight: 32)
            if novels.chart.hasPeriods {
                Picker("Period", selection: $novels.period) {
                    ForEach(WebNovelPeriod.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("webNovelPeriodPicker")
            }
            if novels.error != nil, novels.selected != nil {
                Text("Loaded earlier · Refresh to try again").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("webNovelSavedList")
            }
            if novels.isLoading && novels.books.isEmpty { ProgressView("Loading chart…").frame(maxWidth: .infinity).padding(.vertical, 40) }
            if let error = novels.error {
                VStack(alignment: .leading, spacing: 10) {
                    Text(error).font(.subheadline).accessibilityIdentifier("webNovelFeedError")
                    Button("Try again") { Task { await novels.load(force: true) } }.buttonStyle(.bordered).disabled(novels.isLoading)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 14))
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(novels.books) { novel in
                    WebNovelRow(novel: novel, caption: novels.selection.caption, close: close)
                    Divider()
                }
            }.accessibilityIdentifier("webNovelList")
            if novels.isLoading && !novels.books.isEmpty { ProgressView("Loading…").frame(maxWidth: .infinity) }
            else if novels.canLoadMore {
                Button("Load more") { Task { await novels.loadMore() } }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("webNovelLoadMore")
            }
            if !novels.books.isEmpty {
                Text("Top \(novels.books.count) of \(novels.source.fullName)’s \(novels.selection.caption)." + (novels.source == .qidian
                     ? " Books still being written may be missing from Z-Library or incomplete there." : ""))
                    .font(.caption).foregroundStyle(.secondary)
                Link("Chart on \(novels.source.title)", destination: novels.selection.pageURL).font(.caption).accessibilityIdentifier("webNovelSource")
            }
        }
        .task(id: novels.selection) { await novels.load() }
        .onChange(of: catalog.matchingContextID) { _, _ in matching.invalidate() }
        .onChange(of: catalog.connected) { _, connected in if !connected { matching.invalidate() } }
    }
    private var categoryMenu: some View {
        Menu {
            Picker("Category", selection: $novels.category) {
                ForEach(WebNovelCategory.all) { Text($0.title).tag($0.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(WebNovelCategory.titled(novels.category)); Image(systemName: "chevron.down").font(.caption)
            }.font(.subheadline.weight(.medium)).foregroundStyle(theme.accent).frame(minHeight: 32).contentShape(Rectangle())
        }.accessibilityLabel("Category, " + WebNovelCategory.titled(novels.category)).accessibilityIdentifier("webNovelCategory")
    }
}

private struct WebNovelRow: View {
    let novel: WebNovel
    let caption: String
    let close: () -> Void
    @EnvironmentObject private var novels: WebNovelStore
    @EnvironmentObject private var matching: BestsellerMatching
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.leafTheme) private var theme
    @State private var connection = false
    private var state: BestsellerMatchState? { matching.state(for: novel) }
    private var existing: Book? { novels.existing(novel, in: library, candidates: state?.editions.map(\.book) ?? []) }
    private var page: WebNovelBookView { WebNovelBookView(novel: novel, caption: caption, close: close) }
    /// Read out as one item: place, title, who and what, the chart's count, then the synopsis.
    private var spoken: String {
        (["\(novel.rank). \(novel.title)", novel.byline, novel.figure, novel.summary].filter { !$0.isEmpty }).joined(separator: ", ")
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(novel.rank)").font(.headline.monospacedDigit()).foregroundStyle(novel.rank <= 3 ? theme.accent : Color.secondary)
                .frame(width: 26, alignment: .trailing).accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 8) {
                NavigationLink { page } label: {
                    HStack(alignment: .top, spacing: 12) {
                        WebNovelCover(novel: novel).frame(width: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(novel.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                            Text(novel.byline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !novel.figure.isEmpty { Text(novel.figure).font(.caption.weight(.medium)).foregroundStyle(theme.accent) }
                            Text(novel.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(spoken).accessibilityIdentifier("webNovelRow-\(novel.rank)")
                HStack(spacing: 10) { action }.font(.caption)
            }
        }
        .padding(.vertical, 14)
        .task(id: "\(novel.id):\(catalog.matchingContextID):\(catalog.connected)") {
            if existing == nil { await matching.resolve(novel, catalog: catalog) }
        }
        .sheet(isPresented: $connection) { ZLibraryConnectionView() }
    }
    @ViewBuilder private var action: some View {
        if existing != nil {
            Label("In library", systemImage: "checkmark").foregroundStyle(theme.accent).accessibilityIdentifier("webNovelOwned-\(novel.rank)")
        } else if catalog.downloadingID != nil, catalog.downloadingID == state?.automatic?.id {
            ProgressView("Adding…")
        } else if let edition = state?.automatic {
            Text([edition.fileExtension.uppercased(), edition.size].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
            Button { catalog.add(edition, library: library) } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.bordered).disabled(catalog.downloadingID != nil || library.isImporting)
                .accessibilityLabel("Add \(novel.title) to library").accessibilityIdentifier("webNovelAdd-\(novel.rank)")
        } else {
            switch state {
            case .loading, .none: ProgressView("Checking…")
            case .connectionRequired:
                Button("Connect") { connection = true }.buttonStyle(.bordered).accessibilityIdentifier("webNovelConnect-\(novel.rank)")
            case .ready(let editions):
                Text(editions.isEmpty ? "No match yet" : editions.count == 1 ? "1 possible edition" : "\(editions.count) editions").foregroundStyle(.secondary)
                NavigationLink { page } label: { Text(editions.isEmpty ? "Find" : "Choose") }
                    .buttonStyle(.bordered).accessibilityIdentifier("webNovelChoose-\(novel.rank)")
            case .failed(_, let reason):
                Text(reason).foregroundStyle(.secondary).accessibilityIdentifier("webNovelEditionsFailed-\(novel.rank)")
                Button("Try again") { Task { await matching.resolve(novel, catalog: catalog, force: true) } }
            }
        }
    }
}

struct WebNovelBookView: View {
    let novel: WebNovel
    /// The chart the reader came from, such as "月票榜 · 全站".
    let caption: String
    let close: () -> Void
    @EnvironmentObject private var novels: WebNovelStore
    @EnvironmentObject private var matching: BestsellerMatching
    @EnvironmentObject private var catalog: ZLibraryStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.leafTheme) private var theme
    @State private var connection = false
    @State private var search = false
    private var state: BestsellerMatchState? { matching.state(for: novel) }
    private var existing: Book? { novels.existing(novel, in: library, candidates: state?.editions.map(\.book) ?? []) }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                WebNovelCover(novel: novel).frame(width: 130)
                Text(novel.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center).accessibilityIdentifier("webNovelDetailTitle")
                Text(novel.author).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    Text([novel.category, novel.subcategory, novel.length].filter { !$0.isEmpty }.joined(separator: " · "))
                    Text((["#\(novel.rank)", caption] + (novel.figure.isEmpty ? [] : [novel.figure])).joined(separator: " · "))
                        .accessibilityIdentifier("webNovelRanking")
                }.font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Text("About this book").font(.headline)
                    Text(novel.summary.isEmpty ? "\(novel.source.title) lists no synopsis for this book." : novel.summary).font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("webNovelSynopsis")
                    Link("View on \(novel.source.title)", destination: novel.sourceURL).font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading)
                BookReviewsSection(query: BookReviewQuery(novel))
                ListedBookEditions(state: state, close: close, connect: { connection = true }, search: { search = true },
                                   retry: { Task { await matching.resolve(novel, catalog: catalog, force: true) } })
            }.padding(24).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .background(theme.canvas).navigationTitle("Book details").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { ListedBookAddBar(owned: existing != nil, edition: state?.automatic, close: close) }
        .onAppear { novels.viewingBook = novel; catalog.resetImportResult() }
        .onDisappear { if novels.viewingBook?.id == novel.id { novels.viewingBook = nil } }
        .task(id: "\(catalog.matchingContextID):\(catalog.connected)") { await matching.resolve(novel, catalog: catalog) }
        .sheet(isPresented: $connection) { ZLibraryConnectionView() }
        .navigationDestination(isPresented: $search) { BestsellerCatalogSearch(initialQuery: novel.title + " " + novel.author, close: close) }
    }
}
