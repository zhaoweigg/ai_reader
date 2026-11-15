import Foundation

/// One readable unit of a book: an EPUB/TXT/FB2 section or a PDF page.
struct BookTextSection: Codable, Equatable {
    let label: String
    let text: String
}

/// Where the reader is: tools never return text after this point.
struct BookTextBoundary: Equatable {
    let section: Int
    let offset: Int
}

/// Supplies plain section text in the same coordinates as `boundary(for:)`.
@MainActor
protocol BookTextSource: AnyObject {
    func bookSectionCount() async throws -> Int
    func bookSectionText(_ index: Int) async throws -> BookTextSection
    func bookBoundary(for locator: String) async throws -> BookTextBoundary?
}

/// Plain text of the sections a reader has reached, built on demand and kept on
/// device so later searches are instant. Text after the reading boundary is
/// never returned by any query.
@MainActor
final class BookTextIndex {
    struct Coverage: Equatable {
        let indexed: Int
        let eligible: Int
        var complete: Bool { indexed >= eligible }
    }
    struct Hit: Equatable {
        let section: Int
        let chapter: String
        let position: Int
        let text: String
        let terms: Int
    }
    private weak var source: (any BookTextSource)?
    private let directory: URL?
    private var sections: [Int: BookTextSection] = [:]
    private var characters = 0
    static let characterLimit = 24_000_000
    static let sectionLimit = 400_000

    init(source: any BookTextSource, directory: URL?) {
        self.source = source; self.directory = directory
    }
    /// Text saved on this device for a book that is not open: only sections
    /// already prepared can be read, and nothing is extracted.
    init(savedIn directory: URL) {
        self.source = nil; self.directory = directory
    }

    /// The reading position the saved text was last prepared for. Searching a book
    /// that is not open trusts it only while the reader has not gone back before it.
    struct SavedPosition: Codable, Equatable {
        let locator: String
        let section: Int
        let offset: Int
        /// The book's progress then, 0...1, to tell whether its saved place is later.
        let progress: Double
        var boundary: BookTextBoundary { BookTextBoundary(section: section, offset: offset) }
        /// Whether searching up to this position stays within what the reader has
        /// read, given where the book is saved now.
        func covers(locator current: String, progress now: Double) -> Bool {
            current == locator || now + 0.0005 >= progress
        }
    }
    static func savedPosition(in directory: URL) -> SavedPosition? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("position.json")) else { return nil }
        return try? JSONDecoder().decode(SavedPosition.self, from: data)
    }
    func savePosition(locator: String, progress: Double, boundary: BookTextBoundary) {
        guard let directory, !locator.isEmpty else { return }
        let position = SavedPosition(locator: locator, section: boundary.section, offset: boundary.offset, progress: min(1, max(0, progress)))
        guard Self.savedPosition(in: directory) != position, let data = try? JSONEncoder().encode(position) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try? data.write(to: directory.appendingPathComponent("position.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    /// Loads the saved sections up to `boundary` without the book. Sections never
    /// prepared on this device are missing from the coverage.
    func loadSaved(through boundary: BookTextBoundary) -> Coverage {
        guard boundary.section >= 0 else { return Coverage(indexed: 0, eligible: 0) }
        var indexed = 0
        for index in 0...boundary.section {
            if sections[index] == nil, characters < Self.characterLimit, let saved = load(index) { remember(saved, at: index) }
            if sections[index] != nil { indexed += 1 }
        }
        return Coverage(indexed: indexed, eligible: boundary.section + 1)
    }

    /// Loads sections 0...boundary.section from memory, disk or the book, until the deadline.
    func prepare(through boundary: BookTextBoundary, deadline: Date, progress: ((Int, Int) -> Void)? = nil) async throws -> Coverage {
        guard let source else { throw CancellationError() }
        let count = try await source.bookSectionCount()
        let last = min(boundary.section, count - 1)
        guard last >= 0 else { return Coverage(indexed: 0, eligible: 0) }
        var indexed = 0
        for index in 0...last {
            try Task.checkCancellation()
            if sections[index] == nil {
                if let cached = load(index) { remember(cached, at: index) }
                // Past the deadline, still use sections saved earlier on this device.
                else if Date() < deadline, characters < Self.characterLimit {
                    do {
                        let section = try await source.bookSectionText(index)
                        let bounded = BookTextSection(label: String(section.label.prefix(200)), text: String(section.text.prefix(Self.sectionLimit)))
                        remember(bounded, at: index); store(bounded, at: index)
                    } catch is CancellationError { throw CancellationError() }
                    catch { remember(BookTextSection(label: "", text: ""), at: index) } // Unreadable this launch; not saved.
                    // Let page turns and typing run between sections.
                    await Task.yield()
                }
            }
            if sections[index] != nil { indexed += 1 }
            if index % 8 == 0 { progress?(index + 1, last + 1) }
        }
        return Coverage(indexed: indexed, eligible: last + 1)
    }

    /// Loads one section, for reading a passage without preparing the whole book.
    func prepareSection(_ index: Int) async throws {
        guard sections[index] == nil else { return }
        if let cached = load(index) { remember(cached, at: index); return }
        guard let source else { throw CancellationError() }
        let section = try await source.bookSectionText(index)
        let bounded = BookTextSection(label: String(section.label.prefix(200)), text: String(section.text.prefix(Self.sectionLimit)))
        remember(bounded, at: index); store(bounded, at: index)
    }

    private func remember(_ section: BookTextSection, at index: Int) {
        characters += section.text.count - (sections[index]?.text.count ?? 0)
        sections[index] = section
    }
    private func text(_ index: Int, within boundary: BookTextBoundary) -> String? {
        guard index <= boundary.section, let section = sections[index] else { return nil }
        guard index == boundary.section else { return section.text }
        // Boundaries and positions are UTF-16 offsets, as in the reader's JavaScript.
        let text = section.text as NSString
        return text.substring(to: min(text.length, max(0, boundary.offset)))
    }
    func label(_ index: Int) -> String {
        let label = sections[index]?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? "Section \(index + 1)" : label
    }

    /// Ranked passages containing any of the terms. Passages with more distinct
    /// terms rank higher; each term's first mention is always kept, then results
    /// spread across chapters.
    func search(_ terms: [String], within boundary: BookTextBoundary, limit: Int) -> (hits: [Hit], counts: [String: Int]) {
        let needles = terms.map { $0.lowercased() }
        var counts = Dictionary(uniqueKeysWithValues: terms.map { ($0, 0) })
        struct Cluster { var section: Int; var start: Int; var end: Int; var terms: Set<Int>; var count: Int }
        var clusters: [Cluster] = [], firsts: [Int: Int] = [:]
        for index in sections.keys.sorted() where index <= boundary.section {
            guard let text = text(index, within: boundary), !text.isEmpty else { continue }
            let folded = text.lowercased() as NSString
            var found: [(offset: Int, term: Int)] = []
            for (term, needle) in needles.enumerated() where !needle.isEmpty {
                var range = NSRange(location: 0, length: folded.length), matches = 0
                while matches < 400 {
                    let match = folded.range(of: needle, options: [.literal], range: range)
                    guard match.location != NSNotFound else { break }
                    found.append((match.location, term)); matches += 1
                    counts[terms[term], default: 0] += 1
                    let next = NSMaxRange(match); range = NSRange(location: next, length: folded.length - next)
                }
            }
            for hit in found.sorted(by: { $0.offset < $1.offset }) {
                if var last = clusters.last, last.section == index, hit.offset - last.end < 240 {
                    last.end = hit.offset + needles[hit.term].utf16.count; last.terms.insert(hit.term); last.count += 1
                    clusters[clusters.count - 1] = last
                } else {
                    clusters.append(Cluster(section: index, start: hit.offset, end: hit.offset + needles[hit.term].utf16.count, terms: [hit.term], count: 1))
                }
                if firsts[hit.term] == nil { firsts[hit.term] = clusters.count - 1 }
            }
        }
        var chosen: [Int] = []
        for cluster in firsts.values.sorted() where !chosen.contains(cluster) && chosen.count < limit { chosen.append(cluster) }
        var usedSections = Set(chosen.map { clusters[$0].section })
        let ranked = clusters.indices.sorted { lhs, rhs in
            let a = clusters[lhs], b = clusters[rhs]
            return a.terms.count != b.terms.count ? a.terms.count > b.terms.count
                : a.count != b.count ? a.count > b.count : lhs > rhs // Prefer recent appearances on ties.
        }
        for pass in 0..<2 {
            for index in ranked where chosen.count < limit && !chosen.contains(index) {
                // First pass: one passage per section; second pass fills remaining slots.
                if pass == 0 && usedSections.contains(clusters[index].section) { continue }
                chosen.append(index); usedSections.insert(clusters[index].section)
            }
        }
        let hits = chosen.sorted().compactMap { index -> Hit? in
            let cluster = clusters[index]
            guard let text = text(cluster.section, within: boundary) as NSString? else { return nil }
            let start = max(0, cluster.start - 150), end = min(text.length, max(cluster.end + 210, start + 360), start + 600)
            return Hit(section: cluster.section, chapter: label(cluster.section), position: cluster.start,
                       text: text.substring(with: NSRange(location: start, length: end - start)), terms: cluster.terms.count)
        }
        return (hits, counts)
    }

    func read(section: Int, position: Int, length: Int, within boundary: BookTextBoundary) -> (text: String, end: Int, more: Bool)? {
        guard let text = text(section, within: boundary) as NSString? else { return nil }
        let start = min(max(0, position), text.length), end = min(text.length, start + length)
        return (text.substring(with: NSRange(location: start, length: end - start)), end, end < text.length)
    }

    // MARK: Disk cache
    private func file(_ index: Int) -> URL? { directory?.appendingPathComponent("\(index).json") }
    private func load(_ index: Int) -> BookTextSection? {
        guard let file = file(index), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(BookTextSection.self, from: data)
    }
    private func store(_ section: BookTextSection, at index: Int) {
        guard let directory, let file = file(index), let data = try? JSONEncoder().encode(section) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
