import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// All geometry is top-left source-image pixels. Preview, OCR and export use this renderer.
enum Renderer {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// Unedited captures need only a crop; edited captures must be sanitized first.
    static func recognitionImage(source: CGImage, crop: CGRect, items: [Annotation]) throws -> CGImage {
        guard items.isEmpty else { return try render(source: source, crop: crop, items: items) }
        let rect = crop.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height)).integral
        guard rect.width >= 1, rect.height >= 1, let image = source.cropping(to: rect) else {
            throw FastShotError.message("The selection is empty. Try selecting an area again.")
        }
        return image
    }
    static func render(source: CGImage, crop: CGRect, items: [Annotation]) throws -> CGImage {
        let crop = crop.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height)).integral
        guard crop.width >= 1, crop.height >= 1, let base = source.cropping(to: crop),
              let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FastShotError.message("The selection is empty or too large to render. Try a smaller area.")
        }
        context.translateBy(x: 0, y: CGFloat(base.height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        drawImage(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        // Effects always precede annotations; solid redactions always come last.
        for item in items where item.tool == .blur || item.tool == .pixelate {
            let rect = item.bounds.integral.intersection(bounds)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            let ci = CIImage(cgImage: base)
            let effect: CIImage
            if item.tool == .blur { effect = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: item.strength]) }
            else { effect = ci.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(2, item.strength)]) }
            let ciRect = CGRect(x: rect.minX, y: CGFloat(base.height) - rect.maxY, width: rect.width, height: rect.height)
            if let image = ciContext.createCGImage(effect, from: ciRect) { drawImage(image, in: rect) }
        }
        for item in items where item.tool != .redact && item.tool != .blur && item.tool != .pixelate { draw(item, context: context) }
        context.setShouldAntialias(false)
        for item in items where item.tool == .redact {
            context.setFillColor(NSColor(hex: item.color).cgColor)
            context.fill(item.bounds.integral.intersection(bounds))
        }
        guard let image = context.makeImage() else { throw FastShotError.message("Could not finish rendering the screenshot.") }
        return image
    }
    static func drawImage(_ image: CGImage, in rect: CGRect) {
        NSImage(cgImage: image, size: .zero).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
    static func draw(_ item: Annotation, context: CGContext) {
        guard let first = item.points.first else { return }
        let last = item.points.last ?? first
        context.saveGState(); defer { context.restoreGState() }
        let color = NSColor(hex: item.color)
        context.setStrokeColor(color.cgColor); context.setFillColor(color.cgColor)
        context.setLineWidth(item.width); context.setLineCap(.round); context.setLineJoin(.round)
        switch item.tool {
        case .rect: context.stroke(item.bounds)
        case .ellipse: context.strokeEllipse(in: item.bounds)
        case .line, .arrow:
            context.move(to: first); context.addLine(to: last); context.strokePath()
            if item.tool == .arrow {
                let angle = atan2(last.y - first.y, last.x - first.x), length = min(max(12, item.width * 4), hypot(last.x - first.x, last.y - first.y))
                context.move(to: last)
                context.addLine(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
                context.closePath(); context.fillPath()
            }
        case .pen, .highlight:
            if item.tool == .highlight { context.setAlpha(0.4); context.setLineWidth(item.width * 5); context.setLineCap(.butt) }
            context.move(to: first)
            for point in item.points.dropFirst() { context.addLine(to: point) }
            if item.points.count == 1 { context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            context.strokePath()
        case .text:
            let font = NSFont(name: "Geist-SemiBold", size: item.fontSize) ?? NSFont.systemFont(ofSize: item.fontSize, weight: .semibold)
            (item.text as NSString).draw(at: first, withAttributes: [.font: font, .foregroundColor: color])
        case .step:
            context.fillEllipse(in: item.bounds)
            let font = NSFont.systemFont(ofSize: item.fontSize * (item.number < 10 ? 1.15 : 0.85), weight: .semibold)
            let fill = color.usingColorSpace(.sRGB) ?? .black
            let luminance = fill.redComponent * 0.299 + fill.greenComponent * 0.587 + fill.blueComponent * 0.114
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: luminance > 0.6 ? NSColor.black : NSColor.white]
            let text = String(item.number) as NSString, size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: first.x - size.width / 2, y: first.y - size.height / 2), withAttributes: attrs)
        default: break
        }
    }
    static func encode(_ image: CGImage, format: String, quality: Double = 90) throws -> Data {
        let data = NSMutableData()
        let type = format == "jpeg" ? UTType.jpeg.identifier : UTType.png.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw FastShotError.message("Could not create image encoder.") }
        // Fresh raster encoding: no source metadata, layers or attachments are passed through.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality / 100] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FastShotError.message("Could not encode the screenshot.") }
        return data as Data
    }
}
