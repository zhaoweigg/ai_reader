import Foundation

/// Streams a `.tar.bz2` archive to disk with the system bzip2 library. Entries
/// are written under `destination` only; absolute paths, `..` components and
/// links are rejected so a downloaded archive can never escape its directory.
enum TarBzip2Extractor {
    enum Failure: LocalizedError {
        case corrupt(String), unsafePath(String), io(String)
        var errorDescription: String? {
            switch self {
            case .corrupt(let detail): return "The voice archive is damaged (\(detail))."
            case .unsafePath(let path): return "The voice archive contains an unsafe path (\(path))."
            case .io(let detail): return "Could not write the voice files (\(detail))."
            }
        }
    }

    static func extract(archive: URL, into destination: URL, progress: ((Int64) -> Void)? = nil) throws {
        guard let input = InputStream(url: archive) else { throw Failure.io("cannot open archive") }
        input.open(); defer { input.close() }
        var parser = TarParser(destination: destination)
        var stream = bz_stream()
        guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { throw Failure.corrupt("bzip2 init") }
        defer { BZ2_bzDecompressEnd(&stream) }
        let chunk = 1 << 16
        let inBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk); defer { inBuffer.deallocate() }
        let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk * 4); defer { outBuffer.deallocate() }
        var consumed: Int64 = 0
        var finished = false
        while !finished {
            let read = input.read(inBuffer, maxLength: chunk)
            if read < 0 { throw Failure.io(input.streamError?.localizedDescription ?? "read") }
            if read == 0 { throw Failure.corrupt("truncated") }
            consumed += Int64(read); progress?(consumed)
            stream.next_in = UnsafeMutableRawPointer(inBuffer).assumingMemoryBound(to: CChar.self)
            stream.avail_in = UInt32(read)
            repeat {
                stream.next_out = UnsafeMutableRawPointer(outBuffer).assumingMemoryBound(to: CChar.self)
                stream.avail_out = UInt32(chunk * 4)
                let status = BZ2_bzDecompress(&stream)
                guard status == BZ_OK || status == BZ_STREAM_END else { throw Failure.corrupt("bzip2 status \(status)") }
                let produced = chunk * 4 - Int(stream.avail_out)
                if produced > 0 { try parser.feed(UnsafeBufferPointer(start: outBuffer, count: produced)) }
                if status == BZ_STREAM_END { finished = true; break }
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        try parser.finish()
    }

    /// Minimal ustar/GNU/pax reader: regular files and directories only.
    struct TarParser {
        let destination: URL
        private var header: [UInt8] = []
        private var pendingName: String?
        private var remaining = 0
        private var padding = 0
        private var skipping = false
        private var handle: FileHandle?
        private var collecting: [UInt8]?
        private var collectKind: UInt8 = 0
        private var sawEnd = false
        init(destination: URL) { self.destination = destination }

        mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) throws {
            var offset = 0
            while offset < bytes.count {
                if remaining > 0 {
                    let take = min(remaining, bytes.count - offset)
                    let slice = UnsafeBufferPointer(rebasing: bytes[offset..<offset + take])
                    if collecting != nil { collecting!.append(contentsOf: slice) }
                    else if !skipping { try handle?.write(contentsOf: Data(buffer: slice)) }
                    remaining -= take; offset += take
                    if remaining == 0 { try endEntry() }
                    continue
                }
                if padding > 0 {
                    let take = min(padding, bytes.count - offset); padding -= take; offset += take; continue
                }
                let need = 512 - header.count
                let take = min(need, bytes.count - offset)
                header.append(contentsOf: bytes[offset..<offset + take]); offset += take
                if header.count == 512 { try beginEntry(); header.removeAll(keepingCapacity: true) }
            }
        }
        mutating func finish() throws {
            if remaining > 0 || collecting != nil { throw Failure.corrupt("unexpected end") }
            try handle?.close(); handle = nil
        }
        private func field(_ start: Int, _ length: Int) -> String {
            let slice = header[start..<start + length].prefix { $0 != 0 }
            return String(decoding: slice, as: UTF8.self)
        }
        private func octal(_ start: Int, _ length: Int) -> Int? {
            let text = field(start, length).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? 0 : Int(text, radix: 8)
        }
        private mutating func beginEntry() throws {
            if header.allSatisfy({ $0 == 0 }) { sawEnd = true; return }
            if sawEnd { return }
            guard let size = octal(124, 12) else { throw Failure.corrupt("size") }
            let kind = header[156]
            var name = field(0, 100)
            let prefix = field(345, 155)
            if field(257, 6).hasPrefix("ustar"), !prefix.isEmpty { name = prefix + "/" + name }
            if let pendingName { name = pendingName; self.pendingName = nil }
            remaining = size; padding = (512 - size % 512) % 512
            skipping = false; collecting = nil; collectKind = kind
            switch kind {
            case 0x4C /* L */, 0x78 /* x */: collecting = []
            case 0x67 /* g */: skipping = true
            case 0x35 /* 5 */: try makeDirectory(name); skipping = true
            case 0x30, 0x00, 0x37:
                let url = try safeURL(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                guard let opened = try? FileHandle(forWritingTo: url) else { throw Failure.io(name) }
                handle = opened
            default: skipping = true // links, devices, sparse and unknown entries are never materialized
            }
            if remaining == 0 { try endEntry() }
        }
        private mutating func endEntry() throws {
            if let collected = collecting {
                let text = String(decoding: collected, as: UTF8.self)
                if collectKind == 0x4C { pendingName = String(text.prefix { $0 != "\0" }) }
                else if let path = paxPath(text) { pendingName = path }
                collecting = nil
            }
            try handle?.close(); handle = nil
        }
        private func paxPath(_ records: String) -> String? {
            for line in records.split(separator: "\n") {
                guard let space = line.firstIndex(of: " ") else { continue }
                let record = line[line.index(after: space)...]
                if record.hasPrefix("path=") { return String(record.dropFirst(5)) }
            }
            return nil
        }
        private func makeDirectory(_ name: String) throws {
            try FileManager.default.createDirectory(at: try safeURL(name), withIntermediateDirectories: true)
        }
        private func safeURL(_ name: String) throws -> URL {
            let trimmed = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
            let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !trimmed.hasPrefix("/"), !components.isEmpty, !components.contains(".."), !components.contains(where: { $0.isEmpty }) else {
                throw Failure.unsafePath(name)
            }
            return components.reduce(destination) { $0.appendingPathComponent($1) }
        }
    }
}
