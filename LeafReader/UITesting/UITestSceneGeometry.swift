#if DEBUG
import SwiftUI
import UIKit
import CoreFoundation

/// Explicit fixture for real scene-layout testing when simulated device motion
/// is not reaching UIKit. It is absent from Release and inert without both the
/// UI-testing launch argument and the separate geometry-fixture opt-in flag.
struct UITestSceneGeometryBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { UITestSceneGeometryView() }
    func updateUIView(_ uiView: UIView, context: Context) {}
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) { (uiView as? UITestSceneGeometryView)?.stop() }
}

@MainActor private final class UITestSceneGeometryView: UIView {
    private final class WeakView { weak var value: UITestSceneGeometryView?; init(_ value: UITestSceneGeometryView) { self.value = value } }
    private static var recipients: [String: WeakView] = [:]
    private var names: [String] = []
    private var requested: UIInterfaceOrientation?
    private var outcome = "idle"
    private var errorCode: Int?
    private var errorDomain: String?
    private let orientations: [(String, UIInterfaceOrientation, UIInterfaceOrientationMask)] = [
        ("portrait", .portrait, .portrait), ("landscapeLeft", .landscapeLeft, .landscapeLeft),
        ("landscapeRight", .landscapeRight, .landscapeRight)
    ]
    init() {
        super.init(frame: .zero); isUserInteractionEnabled = false; backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque()) }
    fileprivate func stop() { unregister() }
    override func didMoveToWindow() {
        super.didMoveToWindow(); unregister()
        guard window != nil, UITesting.flag(.sceneGeometryFixture), let id = UITesting.testID?.uuidString else { return }
        isAccessibilityElement = true; accessibilityIdentifier = "uitestSceneGeometry"
        accessibilityLabel = "UI test scene geometry"
        for (direction, _, _) in orientations {
            let name = "com.leafreader.uitest.geometry.\(id).\(direction)"
            names.append(name); Self.recipients[name] = WeakView(self)
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, _, name, _, _ in
                guard let name else { return }
                let key = name.rawValue as String
                Task { @MainActor in UITestSceneGeometryView.recipients[key]?.value?.receive(key) }
            }, name as CFString, nil, .deliverImmediately)
        }
        updateStatus()
    }
    private func unregister() {
        for name in names {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(name as CFString), nil)
            Self.recipients.removeValue(forKey: name)
        }
        names = []; isAccessibilityElement = false
    }
    private func receive(_ name: String) {
        guard names.contains(name), let scene = window?.windowScene, scene.activationState == .foregroundActive,
              let (_, orientation, mask) = orientations.first(where: { name.hasSuffix("." + $0.0) }) else { return }
        requested = orientation; outcome = "pending"; errorCode = nil; errorDomain = nil
        updateStatus()
        // No supported masks, scene delegates, device values, or reader state
        // are replaced. The system can reject this public geometry preference.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let value = error as NSError
                self.outcome = "error"; self.errorCode = value.code; self.errorDomain = value.domain
                self.updateStatus()
            }
        }
    }
    override func layoutSubviews() { super.layoutSubviews(); updateStatus() }
    private func updateStatus() {
        guard isAccessibilityElement, let window, let scene = window.windowScene else { return }
        let actual = scene.effectiveGeometry.interfaceOrientation
        if outcome == "pending", actual == requested { outcome = "applied" }
        var report: [String: Any] = ["fixture": true, "result": outcome, "effectiveOrientation": actual.rawValue,
            "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
            "supportedMask": window.rootViewController?.supportedInterfaceOrientations.rawValue ?? 0]
        if let requested { report["requestedOrientation"] = requested.rawValue }
        if let errorCode { report["errorCode"] = errorCode; report["errorDomain"] = errorDomain }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) { accessibilityValue = String(data: data, encoding: .utf8) }
    }
}
#endif
