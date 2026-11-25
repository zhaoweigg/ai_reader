import Foundation
import Combine

struct BestsellerEdition: Identifiable, Equatable {
    enum Confidence: Int { case possible, titleAndAuthor, isbn }
    let book: ZLibraryBook
    let confidence: Confidence
    var id: String { book.id }
    var canAdd: Bool { book.format != nil }
    /// Surer matches first, then the formats Leaf reads best.
    static func preferred(_ lhs: BestsellerEdition, _ rhs: BestsellerEdition) -> Bool {
        if lhs.confidence.rawValue != rhs.confidence.rawValue { return lhs.confidence.rawValue > rhs.confidence.rawValue }
        func order(_ b: ZLibraryBook) -> Int { b.format == .epub ? 0 : b.format == .pdf ? 1 : b.format != nil ? 2 : 3 }
        return order(lhs.book) == order(rhs.book) ? lhs.id < rhs.id : order(lhs.book) < order(rhs.book)
    }
}

/// A listed work to look up in the catalog: what to search for and how to judge the results.
struct CatalogMatchQuery {
    let id: String
    let isbn: String?
    let search: String
    let rank: @Sendable ([ZLibraryBook]) -> [BestsellerEdition]
    init(_ book: BestsellerBook) {
        id = book.id; isbn = book.isbns.first; search = String((book.title + " " + book.author).prefix(500))
        rank = { BestsellerMatching.rank(book, editions: $0) }
    }
    init(_ novel: WebNovel) {
        id = novel.id; isbn = nil; search = String((novel.title + " " + novel.author).prefix(500))
        rank = { WebNovelText.rank(novel, editions: $0) }
    }
    init(_ book: ListedBook) {
        id = book.id; isbn = book.isbns.first; search = String((book.title + " " + book.author).prefix(500))
        if book.isChinese {
            // The 中文 charts' matching: uploads wrap Chinese titles in their own notes.
            let novel = WebNovel(rank: book.rank, bookID: book.bookID, title: book.title, author: book.author, category: "", subcategory: "",
                                 length: "", figure: "", summary: "")
            rank = { WebNovelText.rank(novel, editions: $0) }
        } else {
            let entry = BestsellerBook(source: .indie, genre: .fiction, rank: book.rank, title: book.title, author: book.author,
                                       summary: "", isbns: book.isbns, sourceURL: book.link ?? URL(string: "https://openlibrary.org")!)
            rank = { BestsellerMatching.rank(entry, editions: $0) }
        }
    }
}

enum BestsellerMatchState: Equatable {
    /// `reason` is the short line a list row shows; `message` is the book page's sentence.
    case loading, ready([BestsellerEdition]), failed(String, reason: String), connectionRequired
    var editions: [BestsellerEdition] { if case .ready(let values) = self { return values }; return [] }
    var automatic: ZLibraryBook? {
        let values = editions.filter { $0.confidence != .possible && $0.canAdd }
        return values.count == 1 && editions.count == 1 ? values[0].book : nil
    }
}

@MainActor final class BestsellerMatching: ObservableObject {
    @Published private(set) var states: [String: BestsellerMatchState] = [:]
    private var context: UUID?
    private let slots = ZLibraryDetailSlots()
    private struct Request {
        let id: UUID
        let task: Task<[BestsellerEdition], Error>
        var readers: Set<UUID>
    }
    private var requests: [String: Request] = [:]
    func state(for book: BestsellerBook) -> BestsellerMatchState? { states[book.id] }
    func state(for novel: WebNovel) -> BestsellerMatchState? { states[novel.id] }
    func state(for book: ListedBook) -> BestsellerMatchState? { states[book.id] }
    func invalidate() {
        requests.values.forEach { $0.task.cancel() }; requests.removeAll(); states.removeAll(); context = nil
    }
    func resolve(_ book: BestsellerBook, catalog: ZLibraryStore, force: Bool = false) async {
        await resolve(CatalogMatchQuery(book), catalog: catalog, force: force)
    }
    func resolve(_ novel: WebNovel, catalog: ZLibraryStore, force: Bool = false) async {
        await resolve(CatalogMatchQuery(novel), catalog: catalog, force: force)
    }
    func resolve(_ book: ListedBook, catalog: ZLibraryStore, force: Bool = false) async {
        await resolve(CatalogMatchQuery(book), catalog: catalog, force: force)
    }
    private func resolve(_ book: CatalogMatchQuery, catalog: ZLibraryStore, force: Bool) async {
        if context != catalog.matchingContextID { invalidate(); context = catalog.matchingContextID }
        if !force, case .ready = states[book.id] { return }
        let key = book.id, reader = UUID(), token = catalog.matchingContextID
        let request: Request
        if var current = requests[key] { current.readers.insert(reader); requests[key] = current; request = current }
        else {
            let id = UUID()
            let task = Task<[BestsellerEdition], Error> { [slots] in
                try await slots.acquire(); defer { slots.release() }
                try Task.checkCancellation()
                var rows: [ZLibraryBook] = []
                if let isbn = book.isbn { rows = try await catalog.matchingSearch(isbn) }
                var ranked = book.rank(rows)
                if ranked.isEmpty {
                    rows += try await catalog.matchingSearch(book.search)
                    ranked = book.rank(rows)
                }
                // Sparse search entries still use the existing selected-edition loader.
                // A failed detail lookup remains a candidate to inspect/retry, never a quick Add.
                var result: [BestsellerEdition] = []
                for candidate in ranked.prefix(15) {
                    try Task.checkCancellation()
                    if candidate.book.fileExtension.isEmpty, let full = try? await catalog.details(candidate.book) {
                        result.append(contentsOf: book.rank([full]))
                    } else { result.append(candidate) }
                }
                return result
            }
            request = Request(id: id, task: task, readers: [reader]); requests[key] = request; states[key] = .loading
        }
        defer { release(reader, key: key, request: request.id) }
        do {
            let result = try await withTaskCancellationHandler { try await request.task.value } onCancel: {
                Task { @MainActor [weak self] in self?.release(reader, key: key, request: request.id) }
            }
            try Task.checkCancellation()
            guard context == token, catalog.matchingContextID == token, requests[key]?.id == request.id else { return }
            states[key] = .ready(result)
        } catch {
            guard context == token, catalog.matchingContextID == token, requests[key]?.id == request.id, !Task.isCancelled, !ZLibraryStore.isCancellation(error) else { return }
            states[key] = ZLibraryRequestFailure.issue(error) == .signInRequired ? .connectionRequired : Self.failure(error)
        }
    }
    /// Says why editions could not be checked, so a refusal on Z-Library's side does not look
    /// like a problem with the book or the reader's connection.
    nonisolated static func failure(_ error: Error) -> BestsellerMatchState {
        switch ZLibraryRequestFailure.issue(error) {
        case .searchRefused?:
            return .failed("Z-Library is refusing searches right now. This is on its side; try again later.", reason: "Z-Library is refusing searches")
        case .accessCheck?, .challenge?:
            return .failed("Z-Library wants its website checked first. Open it from Connection, then try again.", reason: "Z-Library wants a website check")
        case .unreachable?:
            return .failed("Couldn’t reach Z-Library. Check your connection and try again.", reason: "Couldn’t reach Z-Library")
        default:
            return .failed("Z-Library editions could not be checked. Try again or search the catalog.", reason: "Could not check editions")
        }
    }
    private func release(_ reader: UUID, key: String, request id: UUID) {
        guard var value = requests[key], value.id == id else { return }
        value.readers.remove(reader)
        if value.readers.isEmpty {
            value.task.cancel(); requests[key] = nil
            if case .loading = states[key] { states[key] = nil }
        } else { requests[key] = value }
    }
    nonisolated static func rank(_ entry: BestsellerBook, editions: [ZLibraryBook]) -> [BestsellerEdition] {
        let sourceISBNs = Set(entry.isbns.compactMap(BestsellerText.canonicalISBN)), author = BestsellerText.normalized(entry.author)
        var seen: Set<String> = []
        return editions.compactMap { book -> BestsellerEdition? in
            guard seen.insert(book.id).inserted else { return nil }
            let exactISBN = !sourceISBNs.isDisjoint(with: (book.isbns ?? []).compactMap(BestsellerText.canonicalISBN))
            let sameTitle = BestsellerText.compatibleTitles(book.title, entry.title)
            let fullTitle = BestsellerText.normalized(book.title) == BestsellerText.normalized(entry.title)
            let candidateAuthor = BestsellerText.normalized(book.author)
            let sameAuthor = !author.isEmpty && author == candidateAuthor
            let a = Set(author.split(separator: " ")), b = Set(candidateAuthor.split(separator: " "))
            let relatedAuthor = candidateAuthor.isEmpty || (a.count >= 2 && (a.isSubset(of: b) || b.count >= 2 && b.isSubset(of: a)))
            guard exactISBN || sameTitle && (sameAuthor || relatedAuthor) else { return nil }
            return BestsellerEdition(book: book, confidence: exactISBN ? .isbn : sameAuthor && fullTitle ? .titleAndAuthor : .possible)
        }.sorted(by: BestsellerEdition.preferred)
    }
}
