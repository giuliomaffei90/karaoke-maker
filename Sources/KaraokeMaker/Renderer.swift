import AppKit
import CoreText

/// Draws the karaoke lyrics at one instant. Shared by the preview and the export, so both look the same.
/// Works in Core Graphics coordinates (origin at the bottom left).
enum KaraokeRenderer {
    static func draw(_ lines: [Line], style: KaraokeStyle, at time: Double, in ctx: CGContext, size: CGSize) {
        let slots = max(1, style.lineCount)
        let scale = size.height / 1080
        let lineHeight = style.fontSize * scale * style.lineSpacing
        let margin = style.margin * scale
        for i in lines.indices where !lines[i].words.isEmpty {
            let shown = lines.visibility(of: i, slots: slots, leadIn: style.leadIn)
            guard shown.contains(time) else { continue }
            let fade = min(1, (time - shown.lowerBound) / 0.2, (shown.upperBound - time) / 0.2)
            // Row 0 is the top one.
            let row = Double(slots - 1 - i % slots)
            let baseline = switch style.position {
            case .bottom: margin + row * lineHeight
            case .top: size.height - margin - style.fontSize * scale - Double(i % slots) * lineHeight
            case .middle: (size.height - Double(slots) * lineHeight) / 2 + row * lineHeight + lineHeight * 0.3
            }
            drawLine(lines[i], style: style, time: time, baseline: baseline, alpha: fade, scale: scale, in: ctx, width: size.width)
        }
    }

    private static func drawLine(_ line: Line, style: KaraokeStyle, time: Double, baseline: Double, alpha: Double,
                                 scale: Double, in ctx: CGContext, width: Double) {
        // Word boundaries in UTF-16 offsets, which is what Core Text measures.
        var text = ""
        var ranges: [(Int, Int)] = []
        for word in line.words {
            if !text.isEmpty { text += " " }
            let w = style.uppercase ? word.text.uppercased() : word.text
            let from = text.utf16.count
            text += w
            ranges.append((from, text.utf16.count))
        }
        var fontSize = style.fontSize * scale
        var ctLine = makeLine(text, font: style.font(size: fontSize))
        var lineWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        if lineWidth > width * 0.92 {  // too long for the frame: shrink this line only
            fontSize *= width * 0.92 / lineWidth
            ctLine = makeLine(text, font: style.font(size: fontSize))
            lineWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        }
        let x = (width - lineWidth) / 2
        let offsets = ranges.map { (CTLineGetOffsetForStringIndex(ctLine, $0.0, nil), CTLineGetOffsetForStringIndex(ctLine, $0.1, nil)) }

        // How far the sung colour has reached.
        var fillX = 0.0
        if let k = line.words.lastIndex(where: { $0.start <= time }) {
            let word = line.words[k], (a, b) = offsets[k]
            let progress = style.fill == .word ? 1 : min(1, (time - word.start) / max(word.end - word.start, 0.01))
            fillX = a + (b - a) * progress
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(alpha)
        if style.box {
            let pad = fontSize * 0.3
            let rect = CGRect(x: x - pad, y: baseline - fontSize * 0.35, width: lineWidth + pad * 2, height: fontSize * 1.3)
            ctx.setFillColor(style.boxColor.cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: pad, cornerHeight: pad, transform: nil))
            ctx.fillPath()
        }
        if style.shadow.a > 0 && (style.shadowBlur > 0 || style.shadowOffset > 0) {
            let o = style.shadowOffset * scale
            ctx.setShadow(offset: CGSize(width: o, height: -o), blur: style.shadowBlur * scale, color: style.shadow.cgColor)
        }
        // One layer, so the shadow falls from the finished text and not from each pass.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.textMatrix = .identity
        let outline = style.outlineWidth * scale
        func pass(fill: RGBA, stroke: RGBA) {
            if outline > 0 {
                ctx.setTextDrawingMode(.stroke)
                ctx.setLineWidth(outline * 2)  // half of it is covered by the fill
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(stroke.cgColor)
                ctx.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(ctLine, ctx)
            }
            ctx.setTextDrawingMode(.fill)
            ctx.setFillColor(fill.cgColor)
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(ctLine, ctx)
        }
        pass(fill: style.unsung, stroke: style.outline)
        if fillX > 0 {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: baseline - fontSize, width: x + fillX, height: fontSize * 3))
            pass(fill: style.sung, stroke: style.sungOutline)
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
    }

    private static func makeLine(_ text: String, font: NSFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
}
