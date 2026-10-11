import SwiftUI

struct RGBA: Codable, Hashable {
    var r, g, b, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }

    init(_ color: CGColor) {
        let c = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?
            .components ?? [0, 0, 0, 1]
        self.init(c[0], c[1], c[2], c.count > 3 ? c[3] : 1)
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    /// For `ColorPicker`.
    static func binding(_ value: Binding<RGBA>) -> Binding<CGColor> {
        Binding { value.wrappedValue.cgColor } set: { value.wrappedValue = RGBA($0) }
    }
}

/// Sizes are in points of a 1080-pixel-high frame and scale with the output.
struct KaraokeStyle: Codable, Hashable {
    enum Position: String, Codable, CaseIterable { case top, middle, bottom }
    enum Fill: String, Codable, CaseIterable { case smooth, word }

    var fontFamily = "Helvetica Neue"
    var bold = true
    var italic = false
    var uppercase = false
    var fontSize = 72.0
    var sung = RGBA(0.2, 0.75, 1)
    var unsung = RGBA(1, 1, 1)
    var outline = RGBA(0, 0, 0)
    var sungOutline = RGBA(0, 0, 0)
    var outlineWidth = 5.0
    var shadow = RGBA(0, 0, 0, 0.6)
    var shadowBlur = 8.0
    var shadowOffset = 3.0
    var lineCount = 2
    var position = Position.bottom
    var margin = 90.0
    var lineSpacing = 1.3
    var fill = Fill.smooth
    var leadIn = 2.5
    var box = false
    var boxColor = RGBA(0, 0, 0, 0.55)
    /// Behind the lyrics when the media is audio only.
    var background = RGBA(0.06, 0.06, 0.1)

    init() {}

    /// A key missing from the file (a project saved before that option existed) takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KaraokeStyle()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        fontFamily = v(.fontFamily, d.fontFamily)
        bold = v(.bold, d.bold)
        italic = v(.italic, d.italic)
        uppercase = v(.uppercase, d.uppercase)
        fontSize = v(.fontSize, d.fontSize)
        sung = v(.sung, d.sung)
        unsung = v(.unsung, d.unsung)
        outline = v(.outline, d.outline)
        sungOutline = v(.sungOutline, d.sungOutline)
        outlineWidth = v(.outlineWidth, d.outlineWidth)
        shadow = v(.shadow, d.shadow)
        shadowBlur = v(.shadowBlur, d.shadowBlur)
        shadowOffset = v(.shadowOffset, d.shadowOffset)
        lineCount = v(.lineCount, d.lineCount)
        position = v(.position, d.position)
        margin = v(.margin, d.margin)
        lineSpacing = v(.lineSpacing, d.lineSpacing)
        fill = v(.fill, d.fill)
        leadIn = v(.leadIn, d.leadIn)
        box = v(.box, d.box)
        boxColor = v(.boxColor, d.boxColor)
        background = v(.background, d.background)
    }

    func font(size: CGFloat) -> NSFont {
        let traits: NSFontTraitMask = [bold ? .boldFontMask : [], italic ? .italicFontMask : []]
        return NSFontManager.shared.font(withFamily: fontFamily, traits: traits, weight: bold ? 9 : 5, size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}

struct Preset: Codable, Hashable, Identifiable {
    var name: String
    var style: KaraokeStyle
    var id: String { name }
}

extension KaraokeStyle {
    static let presets: [Preset] = {
        let classic = KaraokeStyle()

        var neon = KaraokeStyle()
        neon.fontFamily = "Avenir Next"
        neon.sung = RGBA(1, 0.25, 0.75)
        neon.unsung = RGBA(1, 1, 1, 0.85)
        neon.outline = RGBA(0.15, 0, 0.25)
        neon.sungOutline = RGBA(1, 0.85, 0.95)
        neon.outlineWidth = 2
        neon.shadow = RGBA(1, 0.2, 0.7, 0.9)
        neon.shadowBlur = 22
        neon.shadowOffset = 0

        var pop = KaraokeStyle()
        pop.fontFamily = "Arial Rounded MT Bold"
        pop.uppercase = true
        pop.fontSize = 80
        pop.sung = RGBA(1, 0.85, 0.1)
        pop.outlineWidth = 8
        pop.shadowOffset = 6
        pop.shadowBlur = 0
        pop.shadow = RGBA(0, 0, 0, 0.8)

        var minimal = KaraokeStyle()
        minimal.bold = false
        minimal.fontSize = 60
        minimal.sung = RGBA(1, 1, 1)
        minimal.unsung = RGBA(1, 1, 1, 0.45)
        minimal.outlineWidth = 0
        minimal.shadowBlur = 12
        minimal.shadowOffset = 0
        minimal.shadow = RGBA(0, 0, 0, 0.5)

        var boxed = KaraokeStyle()
        boxed.fontFamily = "Menlo"
        boxed.fontSize = 56
        boxed.sung = RGBA(0.3, 1, 0.4)
        boxed.outlineWidth = 0
        boxed.shadowBlur = 0
        boxed.shadowOffset = 0
        boxed.box = true
        boxed.fill = .word

        var serif = KaraokeStyle()
        serif.fontFamily = "Georgia"
        serif.italic = true
        serif.sung = RGBA(1, 0.78, 0.35)
        serif.unsung = RGBA(0.95, 0.92, 0.85)
        serif.outline = RGBA(0.2, 0.1, 0)
        serif.sungOutline = RGBA(0.35, 0.15, 0)
        serif.outlineWidth = 3
        serif.lineCount = 1

        return [
            Preset(name: tr("Classic"), style: classic), Preset(name: tr("Neon"), style: neon),
            Preset(name: tr("Pop"), style: pop), Preset(name: tr("Minimal"), style: minimal),
            Preset(name: tr("Terminal"), style: boxed), Preset(name: tr("Ballad"), style: serif),
        ]
    }()
}

/// Presets the user saved, in UserDefaults.
enum UserPresets {
    static let key = "userPresets"
    static func decode(_ data: Data) -> [Preset] { (try? JSONDecoder().decode([Preset].self, from: data)) ?? [] }
    static func encode(_ presets: [Preset]) -> Data { (try? JSONEncoder().encode(presets)) ?? Data() }
}
