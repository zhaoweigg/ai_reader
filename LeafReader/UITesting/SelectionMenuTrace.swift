import UIKit
import PDFKit

#if DEBUG
// Selection-menu evidence for the UI tests: which window owns the menu, where touches
// landed and how the scene is oriented. Booleans and geometry only, never book text.
private let selectionMenuTraceQueue = DispatchQueue(label: "Leaf.SelectionMenuTrace", qos: .utility)
@MainActor private var selectionMenuTraceStarted = false
/// Bounded, boolean-only UI-test evidence. No book text, quotes, CFIs, or credentials.
@MainActor func readerSelectionMenuTrace(_ event: String, source: UIView?, context: Bool? = nil, point: CGPoint? = nil, target: UIView? = nil, duration: TimeInterval? = nil, distance: CGFloat? = nil) {
    guard UITesting.isActive, let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
    let url = cache.appendingPathComponent("SelectionMenuUITestTrace.json")
    let reset = !selectionMenuTraceStarted; selectionMenuTraceStarted = true
    let input = source?.selectionFirstResponder as? UITextInput
    var row: [String: Any] = ["event": event, "time": ProcessInfo.processInfo.systemUptime,
        "sourceKey": source?.window?.isKeyWindow ?? false, "hasInputResponder": input != nil,
        "hasNativeRange": input?.selectedTextRange != nil, "nativeRangeEmpty": input?.selectedTextRange?.isEmpty ?? true, "nativeEditInteraction": source?.selectionEditMenu != nil,
        "visibleMenuWindow": source?.window?.windowScene?.windows.contains(where: { $0 is ReaderSelectionWindow && !$0.isHidden }) ?? false]
    if let source {
        if let pdf = source as? PDFView, let page = pdf.currentPage, let document = pdf.document {
            row["pdfPage"] = document.index(for: page)
        }
        row["deviceOrientation"] = UIDevice.current.orientation.rawValue
        if let scene = source.window?.windowScene {
            row["interfaceOrientation"] = scene.effectiveGeometry.interfaceOrientation.rawValue
            let sceneBounds: CGRect
            if #available(iOS 26, *) { sceneBounds = scene.effectiveGeometry.coordinateSpace.bounds }
            else { sceneBounds = scene.coordinateSpace.bounds }
            row["sceneWidth"] = sceneBounds.width; row["sceneHeight"] = sceneBounds.height
            row["windows"] = scene.windows.prefix(8).map { window in
                var controller = window.rootViewController
                var masks: [UInt] = [], types: [String] = []
                while let current = controller, masks.count < 8 {
                    masks.append(current.supportedInterfaceOrientations.rawValue)
                    types.append(String(describing: type(of: current)))
                    controller = current.presentedViewController
                }
                return ["key": window.isKeyWindow, "hidden": window.isHidden, "width": window.bounds.width,
                        "height": window.bounds.height, "controllerMasks": masks, "controllerTypes": types] as [String: Any]
            }
        }
        row["nativeHandles"] = source.nativeSelectionHandleViews.prefix(2).map { handle in
            let rect = source.convert(handle.bounds, from: handle)
            return ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height, "direction": CGFloat(handle.direction.rawValue)]
        }
        row["selectionRects"] = source.selectionRectangles.prefix(8).map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
    }
    if let context { row["context"] = context }
    if let duration { row["touchDuration"] = duration }
    if let distance { row["touchDistance"] = distance }
    if let point { row["x"] = point.x; row["y"] = point.y }
    if let target { row["touchView"] = String(describing: type(of: target)); row["touchInBook"] = source.map { target.isDescendant(of: $0) } ?? false }
    guard let record = try? JSONSerialization.data(withJSONObject: row) else { return }
    selectionMenuTraceQueue.async {
        guard let row = try? JSONSerialization.jsonObject(with: record) as? [String: Any] else { return }
        var rows = reset ? [] : ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? [])
        rows.append(row)
        if rows.count > 80 { rows.removeFirst(rows.count - 80) }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}
#endif
