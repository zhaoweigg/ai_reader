import Foundation
import Combine
import CryptoKit

/// The pinned voice pack: Kokoro v1.1 Chinese+English, ONNX export by k2-fsa.
/// The archive hash is verified before unpacking, and only files under the
/// pack directory are ever written.
struct KokoroModelManifest: Equatable {
    let directoryName: String
    let archiveURL: URL
    let archiveSize: Int64
    let archiveSHA256: String
    let requiredFiles: [String]
    static let current = KokoroModelManifest(
        directoryName: "kokoro-multi-lang-v1_1",
        archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_1.tar.bz2")!,
        archiveSize: 364_816_464,
        archiveSHA256: "a3f4c73d043860e3fd2e5b06f36795eb81de0fc8e8de6df703245edddd87dbad",
        requiredFiles: ["model.onnx", "voices.bin", "tokens.txt", "lexicon-us-en.txt", "lexicon-zh.txt",
                        "phone-zh.fst", "date-zh.fst", "number-zh.fst", "dict/jieba.dict.utf8", "espeak-ng-data/phontab"])
    var archiveSizeLabel: String { ByteCountFormatter.string(fromByteCount: archiveSize, countStyle: .file) }
}

protocol KokoroArchiveDownloading: AnyObject {
    /// Downloads `url` to `destination`, reporting fractional progress. Must throw `CancellationError` when cancelled.
    func download(_ url: URL, to destination: URL, resumeDataURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws
    func cancel()
}

enum KokoroModelError: LocalizedError {
    case notInstalled, lowDiskSpace(Int64), checksum, incomplete(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "The natural voice pack is not downloaded. Download it in listening settings."
        case .lowDiskSpace(let needed): return "Free up about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) of storage to download the voice pack."
        case .checksum: return "The downloaded voice pack did not match its published checksum and was discarded."
        case .incomplete(let file): return "The voice pack is missing \(file). Download it again."
        }
    }
}

/// Owns the on-disk voice pack: download, verification, unpacking and removal.
/// Files live in Application Support (excluded from backups) and are never bundled.
@MainActor final class KokoroModelStore: ObservableObject {
    enum State: Equatable {
        case notInstalled, downloading(Double), verifying, unpacking, ready, failed(String)
        var isBusy: Bool { switch self { case .downloading, .verifying, .unpacking: return true; default: return false } }
    }
    @Published private(set) var state: State = .notInstalled
    let manifest: KokoroModelManifest
    let root: URL
    var modelDirectory: URL { root.appendingPathComponent(manifest.directoryName, isDirectory: true) }
    private var markerURL: URL { root.appendingPathComponent(manifest.directoryName + ".installed") }
    private var archiveURL: URL { root.appendingPathComponent(manifest.directoryName + ".tar.bz2.download") }
    private var resumeURL: URL { root.appendingPathComponent(manifest.directoryName + ".resume") }
    private let downloader: any KokoroArchiveDownloading
    private let freeSpace: (URL) -> Int64?
    private var installTask: Task<Void, Never>?
    var onRemoved: (() -> Void)?

    static let shared = KokoroModelStore()

    init(manifest: KokoroModelManifest = .current, root: URL? = nil, downloader: (any KokoroArchiveDownloading)? = nil,
         freeSpace: ((URL) -> Int64?)? = nil) {
        self.manifest = manifest
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KokoroVoices", isDirectory: true)
        self.downloader = downloader ?? URLSessionArchiveDownloader()
        self.freeSpace = freeSpace ?? { url in
            (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        }
        refresh()
    }

    /// Re-checks the disk; the published marker must carry the archive hash and every required file must exist.
    func refresh() {
        guard !state.isBusy else { return }
        state = isInstalled ? .ready : .notInstalled
    }
    var isInstalled: Bool {
        guard let marker = try? String(contentsOf: markerURL, encoding: .utf8), marker.trimmingCharacters(in: .whitespacesAndNewlines) == manifest.archiveSHA256 else { return false }
        return manifest.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path) }
    }

    func install() {
        guard !state.isBusy, installTask == nil else { return }
        if isInstalled { state = .ready; return }
        state = .downloading(0)
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await performInstall()
                state = .ready
            } catch is CancellationError {
                state = .notInstalled
            } catch {
                state = .failed(error.localizedDescription)
            }
            installTask = nil
        }
    }
    func cancel() {
        downloader.cancel(); installTask?.cancel()
    }
    func remove() {
        cancel()
        try? FileManager.default.removeItem(at: modelDirectory)
        try? FileManager.default.removeItem(at: markerURL)
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: resumeURL)
        state = .notInstalled
        onRemoved?()
    }

    private func performInstall() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var folder = root; try? folder.setResourceValues(values)
        let needed = manifest.archiveSize * 2 + 200_000_000
        if let free = freeSpace(root), free < needed { throw KokoroModelError.lowDiskSpace(needed - free) }
        let archive = archiveURL
        if !archiveMatches(archive) {
            try await downloader.download(manifest.archiveURL, to: archive, resumeDataURL: resumeURL) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(min(max(fraction, 0), 1))
                }
            }
        }
        try Task.checkCancellation()
        state = .verifying
        let digest = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: archive) }.value
        guard digest == manifest.archiveSHA256 else {
            try? FileManager.default.removeItem(at: archive)
            throw KokoroModelError.checksum
        }
        try Task.checkCancellation()
        state = .unpacking
        let destination = root, directory = modelDirectory
        try? FileManager.default.removeItem(at: directory)
        try await Task.detached(priority: .userInitiated) { try TarBzip2Extractor.extract(archive: archive, into: destination) }.value
        for file in manifest.requiredFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
            try? FileManager.default.removeItem(at: directory)
            throw KokoroModelError.incomplete(file)
        }
        try manifest.archiveSHA256.write(to: markerURL, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: archive)
        try? FileManager.default.removeItem(at: resumeURL)
    }
    private func archiveMatches(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else { return false }
        return size == manifest.archiveSize
    }
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Resumable foreground download with progress; resume data survives app restarts on disk.
final class URLSessionArchiveDownloader: NSObject, KokoroArchiveDownloading, URLSessionDownloadDelegate {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var resumeDataURL: URL?
    private var progress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    func download(_ url: URL, to destination: URL, resumeDataURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); defer { lock.unlock() }
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForResource = 6 * 60 * 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session; self.destination = destination; self.resumeDataURL = resumeDataURL
            self.progress = progress; self.continuation = continuation
            if let data = try? Data(contentsOf: resumeDataURL), !data.isEmpty {
                task = session.downloadTask(withResumeData: data)
            } else {
                task = session.downloadTask(with: url)
            }
            task?.resume()
        }
    }
    func cancel() {
        lock.lock(); let task = self.task, resumeURL = resumeDataURL; lock.unlock()
        task?.cancel(byProducingResumeData: { data in
            if let data, let resumeURL { try? data.write(to: resumeURL, options: .atomic) }
        })
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let destination = self.destination; lock.unlock()
        guard let destination else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(error)) }
            return
        }
        if let response = task.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            finish(.failure(URLError(.badServerResponse))); return
        }
        finish(.success(()))
    }
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        session?.finishTasksAndInvalidate(); session = nil; task = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
