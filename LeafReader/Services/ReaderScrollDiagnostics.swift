import UIKit

/// Opt-in recorder for book scroll motion and reader touches, for behavior
/// that only reproduces on a device. It stays off unless a launch with
/// `LEAF_SCROLL_DIAGNOSTICS=1` enabled it for the next 24 hours, and it records
/// offsets, states and timings only, never book text.
@MainActor final class ReaderScrollDiagnostics {
    static let shared = ReaderScrollDiagnostics()
    static let enabledUntilKey = "readerScrollDiagnosticsUntil"
    private(set) var isEnabled = false
    private(set) var file: URL?
    private weak var book: UIScrollView?
    private weak var lastTouch: UITouch?
    private var lastTouchTime: TimeInterval = -1
    private var events: [String] = []
    private var lastFrame = ""
    private var dirty = false
    private var lastWrite: TimeInterval = 0
    private var link: CADisplayLink?
    private final class Ticker: NSObject {
        weak var owner: ReaderScrollDiagnostics?
        @objc func tick() { MainActor.assumeIsolated { owner?.sample() } }
    }
    private lazy var ticker: Ticker = { let ticker = Ticker(); ticker.owner = self; return ticker }()

    func configure(defaults: UserDefaults, environment: [String: String] = ProcessInfo.processInfo.environment, directory: URL?, now: Date = Date()) {
        if environment["LEAF_SCROLL_DIAGNOSTICS"] == "1" {
            defaults.set(now.addingTimeInterval(24 * 3600), forKey: Self.enabledUntilKey)
        }
        guard let directory, let until = defaults.object(forKey: Self.enabledUntilKey) as? Date, until > now else {
            isEnabled = false
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("scroll-diagnostics.json")
        isEnabled = true
        if backgroundObserver == nil {
            backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush(force: true) }
            }
        }
    }
    private var backgroundObserver: NSObjectProtocol?

    /// One reader touch: what it landed on, every native scroll view's state,
    /// whether it was taken as a stop, and the state right after stopping.
    func touch(_ touch: UITouch, scrolls: [UIScrollView], moving: [UIScrollView], coastAge: (UIScrollView) -> TimeInterval?) {
        // Both reader tap recognizers ask about the same touch; record it once.
        guard isEnabled, !(lastTouch === touch && lastTouchTime == touch.timestamp) else { return }
        lastTouch = touch; lastTouchTime = touch.timestamp
        book = scrolls.filter { $0.contentSize.height - $0.bounds.height > 100 }.max { $0.bounds.height < $1.bounds.height } ?? book
        var chain: [String] = []
        var view = touch.view
        while let current = view, chain.count < 8 { chain.append(String(describing: type(of: current))); view = current.superview }
        let point = touch.location(in: nil)
        let states = scrolls.filter { $0.contentSize.height - $0.bounds.height > 100 }.map { scroll in
            var animating = false
            if #available(iOS 17.4, *) { animating = scroll.isScrollAnimating }
            let age = coastAge(scroll).map { String(format: "%.3f", $0) } ?? "null"
            let inside = touch.view?.isDescendant(of: scroll) ?? false
            return "{\"type\":\"\(type(of: scroll))\",\"touchInside\":\(inside),\"moving\":\(moving.contains(scroll)),\"dragging\":\(scroll.isDragging),\"tracking\":\(scroll.isTracking),\"decelerating\":\(scroll.isDecelerating),\"animating\":\(animating),\"coastAge\":\(age),\"y\":\(scroll.contentOffset.y),\"height\":\(scroll.bounds.height),\"contentHeight\":\(scroll.contentSize.height)}"
        }
        append(String(format: "{\"t\":%.4f,\"event\":\"touch\",\"touchTime\":%.4f,\"phase\":%d,\"x\":%.1f,\"y\":%.1f,\"result\":\"%@\",\"chain\":\"%@\",\"scrolls\":[%@]}",
                      CACurrentMediaTime(), touch.timestamp, touch.phase.rawValue, point.x, point.y, moving.isEmpty ? "tap" : "stop",
                      chain.joined(separator: "<"), states.joined(separator: ",")))
        startSampling()
    }

    func afterStop(_ scrolls: [UIScrollView]) {
        guard isEnabled, !scrolls.isEmpty else { return }
        let states = scrolls.map { "{\"type\":\"\(type(of: $0))\",\"decelerating\":\($0.isDecelerating),\"tracking\":\($0.isTracking),\"y\":\($0.contentOffset.y)}" }
        append(String(format: "{\"t\":%.4f,\"event\":\"stopped\",\"scrolls\":[%@]}", CACurrentMediaTime(), states.joined(separator: ",")))
    }

    private func startSampling() {
        guard link == nil else { return }
        let link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Book frames, kept only when the offset or motion state changes.
    private func sample() {
        if let book {
            var animating = false
            if #available(iOS 17.4, *) { animating = book.isScrollAnimating }
            let state = String(format: "%.2f,%d,%d,%d,%d", book.contentOffset.y, book.isTracking ? 1 : 0, book.isDragging ? 1 : 0, book.isDecelerating ? 1 : 0, animating ? 1 : 0)
            if state != lastFrame {
                lastFrame = state
                append(String(format: "{\"t\":%.4f,\"event\":\"frame\",\"y,tracking,dragging,decelerating,animating\":[%@],\"contentHeight\":%.0f}", CACurrentMediaTime(), state, book.contentSize.height))
            }
        }
        flush(force: false)
    }

    private func append(_ event: String) {
        events.append(event)
        if events.count > 8000 { events.removeFirst(events.count - 8000) }
        dirty = true
    }

    func flush(force: Bool) {
        let now = CACurrentMediaTime()
        guard dirty, let file, force || now - lastWrite > 2 else { return }
        lastWrite = now; dirty = false
        let json = "{\"written\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"uptime\":\(now),\"events\":[\n\(events.joined(separator: ",\n"))\n]}"
        try? Data(json.utf8).write(to: file, options: .atomic)
    }
}
