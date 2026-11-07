import Foundation
import Combine

struct BestsellerEdition: Identifiable, Equatable {
    enum Confidence: Int { case possible, titleAndAuthor, isbn }
    let book: ZLibraryBook
    let confidence: Confidence
    var id: String { book.id }
    var canAdd: Bool { book.format != nil }
}

enum BestsellerMatchState: Equatable {
    case loading, ready([BestsellerEdition]), failed(String), connectionRequired
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
    func invalidate() {
        requests.values.forEach { $0.task.cancel() }; requests.removeAll(); states.removeAll(); context = nil
    }
    func resolve(_ book: BestsellerBook, catalog: ZLibraryStore, force: Bool = false) async {
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
                if let isbn = book.isbns.first { rows = try await catalog.matchingSearch(isbn) }
                var ranked = Self.rank(book, editions: rows)
                if ranked.isEmpty {
                    rows += try await catalog.matchingSearch(String((book.title + " " + book.author).prefix(500)))
                    ranked = Self.rank(book, editions: rows)
                }
                // Sparse search entries still use the existing selected-edition loader.
                // A failed detail lookup remains a candidate to inspect/retry, never a quick Add.
                var result: [BestsellerEdition] = []
                for candidate in ranked.prefix(15) {
                    try Task.checkCancellation()
                    if candidate.book.fileExtension.isEmpty, let full = try? await catalog.details(candidate.book) {
                        result.append(contentsOf: Self.rank(book, editions: [full]))
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
            states[key] = ZLibraryRequestFailure.issue(error) == .signInRequired ? .connectionRequired : .failed("Z-Library editions could not be checked. Try again or search the catalog.")
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
        let sourceISBNs = Set(entry.isbns.compactMap(BestsellerText.canonicalISBN)), title = BestsellerText.title(entry.title), author = BestsellerText.normalized(entry.author)
        var seen: Set<String> = []
        return editions.compactMap { book -> BestsellerEdition? in
            guard seen.insert(book.id).inserted else { return nil }
            let exactISBN = !sourceISBNs.isDisjoint(with: (book.isbns ?? []).compactMap(BestsellerText.canonicalISBN))
            let sameTitle = BestsellerText.title(book.title) == title
            let candidateAuthor = BestsellerText.normalized(book.author)
            let sameAuthor = !author.isEmpty && author == candidateAuthor
            let a = Set(author.split(separator: " ")), b = Set(candidateAuthor.split(separator: " "))
            let relatedAuthor = candidateAuthor.isEmpty || (a.count >= 2 && (a.isSubset(of: b) || b.count >= 2 && b.isSubset(of: a)))
            guard exactISBN || sameTitle && (sameAuthor || relatedAuthor) else { return nil }
            return BestsellerEdition(book: book, confidence: exactISBN ? .isbn : sameAuthor ? .titleAndAuthor : .possible)
        }.sorted {
            if $0.confidence.rawValue != $1.confidence.rawValue { return $0.confidence.rawValue > $1.confidence.rawValue }
            func order(_ b: ZLibraryBook) -> Int { b.format == .epub ? 0 : b.format == .pdf ? 1 : b.format != nil ? 2 : 3 }
            return order($0.book) == order($1.book) ? $0.id < $1.id : order($0.book) < order($1.book)
        }
    }
}
