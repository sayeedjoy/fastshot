import AppKit
import Observation

nonisolated enum CaptureMode: String, Codable, CaseIterable, Identifiable {
    case region, window, display
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String { switch self { case .region: "rectangle.dashed"; case .window: "macwindow"; case .display: "menubar.dock.rectangle" } }
}

nonisolated enum Tool: String, CaseIterable, Identifiable {
    case select, pen, line, arrow, rect, ellipse, highlight, text, step, redact, blur, pixelate
    var id: Self { self }
    var title: String {
        switch self {
        case .select: "Select & move"; case .rect: "Rectangle"; case .highlight: "Highlighter"
        case .step: "Numbered step"; default: rawValue.capitalized
        }
    }
    var key: String {
        switch self {
        case .select: "v"; case .pen: "p"; case .line: "l"; case .arrow: "a"; case .rect: "r"; case .ellipse: "e"
        case .highlight: "h"; case .text: "t"; case .step: "n"; case .redact: "x"; case .blur: "b"; case .pixelate: "m"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"; case .pen: "scribble.variable"; case .line: "line.diagonal"; case .arrow: "arrow.up.right"
        case .rect: "square"; case .ellipse: "circle"; case .highlight: "highlighter"; case .text: "character.textbox"
        case .step: "1.circle"; case .redact: "eye.slash"; case .blur: "aqi.medium"; case .pixelate: "squareshape.split.3x3"
        }
    }
}

nonisolated struct Annotation: Identifiable, Equatable {
    let id: UUID
    var tool: Tool
    var points: [CGPoint]
    var color: String
    var width: CGFloat
    var fontSize: CGFloat
    var text = ""
    var number = 1
    var strength: CGFloat = 12

    init(tool: Tool, points: [CGPoint], color: String, width: CGFloat = 3, fontSize: CGFloat = 24) {
        id = UUID(); self.tool = tool; self.points = points; self.color = color; self.width = width; self.fontSize = fontSize
    }
    var bounds: CGRect {
        guard let first = points.first else { return .zero }
        if tool == .step { return CGRect(x: first.x - fontSize, y: first.y - fontSize, width: fontSize * 2, height: fontSize * 2) }
        if tool == .text { return CGRect(origin: first, size: CGSize(width: max(fontSize, CGFloat(text.count) * fontSize * 0.65), height: fontSize * 1.3)) }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }.standardized
    }
    func moved(by delta: CGPoint) -> Self {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return copy
    }
}

@Observable final class EditHistory {
    private(set) var items: [Annotation] = []
    private var past: [[Annotation]] = []
    private var future: [[Annotation]] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    func commit(_ next: [Annotation]) {
        guard next != items else { return }
        past.append(items); items = next; future.removeAll()
    }
    func undo() { guard let previous = past.popLast() else { return }; future.append(items); items = previous }
    func redo() { guard let next = future.popLast() else { return }; past.append(items); items = next }
}

nonisolated enum Geometry {
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    static func pixelCrop(_ rect: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let sx = imageSize.width / viewSize.width, sy = imageSize.height / viewSize.height
        let x = (rect.minX * sx).rounded(), y = (rect.minY * sy).rounded()
        let right = (rect.maxX * sx).rounded(), bottom = (rect.maxY * sy).rounded()
        return CGRect(x: x, y: y, width: right - x, height: bottom - y).intersection(CGRect(origin: .zero, size: imageSize))
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

let annotationPalette = ["#e11d48", "#f97316", "#facc15", "#22c55e", "#0ea5e9", "#6366f1", "#ffffff", "#000000"]
