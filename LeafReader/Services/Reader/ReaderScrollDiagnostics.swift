import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Opt-in recorder for book scroll motion and reader touches, for behavior
/// that only reproduces on a device. It stays off unless a launch with
/// `LEAF_SCROLL_DIAGNOSTICS=1` enabled it for the next 24 hours, and it records
/// offsets, states and timings only, never book text. Earlier launches' events
/// are kept, so a relaunch does not erase what was just reproduced.
@MainActor final class ReaderScrollDiagnostics: ObservableObject {
    static let shared = ReaderScrollDiagnostics()
    static let enabledUntilKey = "readerScrollDiagnosticsUntil"
    static let limit = 8000
    @Published private(set) var isEnabled = false
    @Published private(set) var eventCount = 0
    private(set) var file: URL?
    private var defaults: UserDefaults?
    private var directory: URL?
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
        self.defaults = defaults; self.directory = directory
        if environment["LEAF_SCROLL_DIAGNOSTICS"] == "1" {
            defaults.set(now.addingTimeInterval(24 * 3600), forKey: Self.enabledUntilKey)
        }
        if let directory {
            file = directory.appendingPathComponent("scroll-diagnostics.json")
            eventCount = Self.existingEvents(file!).count
        }
        guard let directory, let until = defaults.object(forKey: Self.enabledUntilKey) as? Date, until > now else {
            isEnabled = false
            return
        }
        start(directory: directory, now: now)
    }

    /// Settings › Diagnostics turns recording on without a special launch; it
    /// then stays on until turned off there.
    func setEnabled(_ enabled: Bool, now: Date = Date()) {
        guard let defaults, let directory else { return }
        if enabled {
            defaults.set(now.addingTimeInterval(365 * 24 * 3600), forKey: Self.enabledUntilKey)
            if !isEnabled { start(directory: directory, now: now) }
        } else {
            defaults.removeObject(forKey: Self.enabledUntilKey)
            flush(force: true)
            isEnabled = false
        }
    }

    /// Forgets everything recorded so far, on disk too.
    func clear() {
        // The last sampled frame is kept, so a still page is not logged again
        // right after clearing; the next change is.
        events = []; eventCount = 0; dirty = false
        if let file { try? FileManager.default.removeItem(at: file) }
        if isEnabled { note("cleared") }
    }

    /// Bytes on disk, for the Settings row.
    var fileSize: Int64 {
        guard let file, let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    private func start(directory: URL, now: Date) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("scroll-diagnostics.json")
        self.file = file
        isEnabled = true
        events = Self.existingEvents(file)
        note("launch", ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
                        "date": ISO8601DateFormatter().string(from: now), "kept": events.count])
        if backgroundObserver == nil {
            backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush(force: true) }
            }
        }
    }
    private var backgroundObserver: NSObjectProtocol?

    /// Events written by earlier launches, re-encoded one per line.
    private static func existingEvents(_ file: URL) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return [] }
        return events.suffix(limit).compactMap { event in
            (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Any reader event worth lining up against the frames: a recognizer firing,
    /// a bridge message, the controls changing.
    func note(_ event: String, _ fields: [String: Any] = [:]) {
        guard isEnabled else { return }
        var payload: [String: Any] = ["t": CACurrentMediaTime(), "event": event]
        for (key, value) in fields { payload[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        append(line)
        startSampling()
    }

    /// Follows every touch on the reader surface, including ones the tap
    /// recognizers never get, so touch phases line up with the frames.
    func observe(_ view: UIView) {
        guard isEnabled, !(view.gestureRecognizers ?? []).contains(where: { $0 is ReaderTouchObserver }) else { return }
        view.addGestureRecognizer(ReaderTouchObserver(diagnostics: self))
    }

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
        if events.count > Self.limit { events.removeFirst(events.count - Self.limit) }
        eventCount = events.count
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

/// Logs touch phases without ever recognizing, so the real recognizers behave
/// as they would without it.
@MainActor final class ReaderTouchObserver: UIGestureRecognizer {
    private weak var diagnostics: ReaderScrollDiagnostics?
    private var start: CGPoint = .zero
    private var lastLogged: CGPoint = .zero
    init(diagnostics: ReaderScrollDiagnostics) {
        self.diagnostics = diagnostics
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        start = touch.location(in: nil); lastLogged = start
        log("touchBegan", touch, event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        let point = touch.location(in: nil)
        guard hypot(point.x - lastLogged.x, point.y - lastLogged.y) >= 4 else { return }
        lastLogged = point
        log("touchMoved", touch, event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if let touch = touches.first { log("touchEnded", touch, event) }
        if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { state = .failed }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        if let touch = touches.first { log("touchCancelled", touch, event) }
        if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { state = .failed }
    }
    override func reset() { super.reset() }
    private func log(_ phase: String, _ touch: UITouch, _ event: UIEvent) {
        let point = touch.location(in: nil)
        diagnostics?.note(phase, ["touchTime": touch.timestamp, "x": point.x, "y": point.y, "tapCount": touch.tapCount,
                                   "fromStart": hypot(point.x - start.x, point.y - start.y), "touches": event.allTouches?.count ?? 1,
                                   "view": String(describing: type(of: touch.view ?? UIView()))])
    }
}
