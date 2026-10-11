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
    /// How much the word being sung grows: 0.2 is 20 % bigger.
    var pop = 0.0
    /// Box behind the word being sung; transparent for none.
    var highlight = RGBA(0, 0, 0, 0)
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
        pop = v(.pop, d.pop)
        highlight = v(.highlight, d.highlight)
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
    /// Built-in looks. `tweak` edits a copy of the default style, so each preset lists only what it changes.
    static let presets: [Preset] = {
        func preset(_ name: String, _ tweak: (inout KaraokeStyle) -> Void) -> Preset {
            var s = KaraokeStyle()
            tweak(&s)
            return Preset(name: tr(name), style: s)
        }
        return [
            preset("Classic") { _ in },
            preset("Pop") {
                $0.fontFamily = "Arial Rounded MT Bold"; $0.uppercase = true; $0.fontSize = 80
                $0.sung = RGBA(1, 0.85, 0.1); $0.outlineWidth = 8
                $0.shadow = RGBA(0, 0, 0, 0.8); $0.shadowBlur = 0; $0.shadowOffset = 6; $0.pop = 0.12
            },
            preset("Caption") {
                $0.fontFamily = "Arial Black"; $0.uppercase = true; $0.fontSize = 76
                $0.unsung = RGBA(1, 1, 1, 0.8); $0.sung = RGBA(1, 1, 1); $0.outlineWidth = 4
                $0.shadowBlur = 0; $0.shadowOffset = 4; $0.shadow = RGBA(0, 0, 0, 0.9)
                $0.highlight = RGBA(0.55, 0.2, 0.95); $0.fill = .word; $0.pop = 0.1
                $0.lineCount = 1; $0.position = .middle
            },
            preset("Highlighter") {
                $0.fontFamily = "Futura"; $0.fontSize = 68
                $0.unsung = RGBA(1, 1, 1); $0.sung = RGBA(1, 1, 1); $0.highlight = RGBA(0.1, 0.7, 0.35)
                $0.outlineWidth = 0; $0.shadowBlur = 10; $0.shadowOffset = 0; $0.fill = .word
            },
            preset("Bounce") {
                $0.fontFamily = "Arial Rounded MT Bold"; $0.fontSize = 78
                $0.sung = RGBA(1, 0.5, 0.1); $0.unsung = RGBA(1, 0.95, 0.85); $0.outline = RGBA(0.3, 0.1, 0)
                $0.sungOutline = RGBA(0.3, 0.1, 0); $0.outlineWidth = 6; $0.shadowOffset = 5; $0.shadowBlur = 2
                $0.fill = .word; $0.pop = 0.3
            },
            preset("Neon") {
                $0.fontFamily = "Avenir Next"; $0.sung = RGBA(1, 0.25, 0.75); $0.unsung = RGBA(1, 1, 1, 0.85)
                $0.outline = RGBA(0.15, 0, 0.25); $0.sungOutline = RGBA(1, 0.85, 0.95); $0.outlineWidth = 2
                $0.shadow = RGBA(1, 0.2, 0.7, 0.9); $0.shadowBlur = 22; $0.shadowOffset = 0
            },
            preset("Synthwave") {
                $0.fontFamily = "Futura"; $0.italic = true; $0.uppercase = true; $0.fontSize = 76
                $0.sung = RGBA(0.3, 1, 1); $0.unsung = RGBA(1, 0.35, 0.85); $0.outline = RGBA(0.2, 0, 0.35)
                $0.sungOutline = RGBA(0, 0.3, 0.4); $0.outlineWidth = 3
                $0.shadow = RGBA(0.6, 0.1, 1, 0.9); $0.shadowBlur = 18; $0.shadowOffset = 0
            },
            preset("Ice") {
                $0.fontFamily = "Avenir Next"; $0.fontSize = 74
                $0.sung = RGBA(0.55, 0.9, 1); $0.unsung = RGBA(1, 1, 1); $0.outline = RGBA(0, 0.25, 0.45)
                $0.sungOutline = RGBA(0, 0.25, 0.45); $0.outlineWidth = 3
                $0.shadow = RGBA(0.3, 0.7, 1, 0.9); $0.shadowBlur = 20; $0.shadowOffset = 0
            },
            preset("Fire") {
                $0.fontFamily = "Impact"; $0.uppercase = true; $0.fontSize = 84; $0.bold = false
                $0.sung = RGBA(1, 0.3, 0); $0.unsung = RGBA(1, 0.85, 0.2); $0.outline = RGBA(0.4, 0.05, 0)
                $0.sungOutline = RGBA(0.4, 0.05, 0); $0.outlineWidth = 4
                $0.shadow = RGBA(1, 0.2, 0, 0.9); $0.shadowBlur = 24; $0.shadowOffset = 0; $0.pop = 0.08
            },
            preset("Gold") {
                $0.fontFamily = "Didot"; $0.fontSize = 80
                $0.sung = RGBA(1, 0.8, 0.3); $0.unsung = RGBA(1, 1, 1); $0.outline = RGBA(0.25, 0.15, 0)
                $0.sungOutline = RGBA(0.35, 0.2, 0); $0.outlineWidth = 2
                $0.shadow = RGBA(0, 0, 0, 0.7); $0.shadowBlur = 14; $0.shadowOffset = 2
            },
            preset("Minimal") {
                $0.bold = false; $0.fontSize = 60; $0.sung = RGBA(1, 1, 1); $0.unsung = RGBA(1, 1, 1, 0.45)
                $0.outlineWidth = 0; $0.shadow = RGBA(0, 0, 0, 0.5); $0.shadowBlur = 12; $0.shadowOffset = 0
            },
            preset("Cinema") {
                $0.bold = false; $0.fontSize = 56; $0.sung = RGBA(1, 0.95, 0.4); $0.outlineWidth = 2
                $0.shadow = RGBA(0, 0, 0, 0.8); $0.shadowBlur = 3; $0.shadowOffset = 2; $0.lineCount = 1; $0.margin = 60
            },
            preset("Ballad") {
                $0.fontFamily = "Georgia"; $0.italic = true; $0.sung = RGBA(1, 0.78, 0.35)
                $0.unsung = RGBA(0.95, 0.92, 0.85); $0.outline = RGBA(0.2, 0.1, 0); $0.sungOutline = RGBA(0.35, 0.15, 0)
                $0.outlineWidth = 3; $0.lineCount = 1
            },
            preset("Script") {
                $0.fontFamily = "Snell Roundhand"; $0.fontSize = 100
                $0.sung = RGBA(1, 0.8, 0.9); $0.unsung = RGBA(1, 1, 1); $0.outlineWidth = 0
                $0.shadow = RGBA(1, 0.6, 0.9, 0.8); $0.shadowBlur = 20; $0.shadowOffset = 0; $0.lineCount = 1
            },
            preset("Lo-fi") {
                $0.fontFamily = "Georgia"; $0.bold = false; $0.fontSize = 62
                $0.sung = RGBA(0.98, 0.8, 0.7); $0.unsung = RGBA(0.75, 0.72, 0.8); $0.outlineWidth = 0
                $0.shadowBlur = 0; $0.shadowOffset = 0; $0.box = true; $0.boxColor = RGBA(0.08, 0.08, 0.14, 0.6)
            },
            preset("Terminal") {
                $0.fontFamily = "Menlo"; $0.fontSize = 56; $0.sung = RGBA(0.3, 1, 0.4)
                $0.outlineWidth = 0; $0.shadowBlur = 0; $0.shadowOffset = 0; $0.box = true; $0.fill = .word
            },
            preset("Typewriter") {
                $0.fontFamily = "American Typewriter"; $0.fontSize = 60
                $0.sung = RGBA(0.1, 0.1, 0.1); $0.unsung = RGBA(0.55, 0.5, 0.45); $0.outlineWidth = 0
                $0.shadowBlur = 0; $0.shadowOffset = 0; $0.box = true; $0.boxColor = RGBA(0.96, 0.93, 0.85, 0.95)
                $0.fill = .word
            },
            preset("Billboard") {
                $0.fontFamily = "Futura"; $0.uppercase = true; $0.fontSize = 70
                $0.sung = RGBA(0, 0, 0); $0.unsung = RGBA(0.55, 0.55, 0.55); $0.outlineWidth = 0
                $0.shadowBlur = 0; $0.shadowOffset = 0; $0.box = true; $0.boxColor = RGBA(1, 1, 1, 0.95); $0.pop = 0.1
            },
            preset("Cyber") {
                $0.fontFamily = "Menlo"; $0.uppercase = true; $0.fontSize = 64
                $0.sung = RGBA(0, 1, 0.6); $0.unsung = RGBA(0.9, 0.9, 0.9); $0.outlineWidth = 0
                $0.shadow = RGBA(1, 0, 0.4, 0.9); $0.shadowBlur = 0; $0.shadowOffset = 4; $0.fill = .word
            },
            preset("Comic") {
                $0.fontFamily = "Marker Felt"; $0.uppercase = true; $0.fontSize = 84; $0.bold = false
                $0.sung = RGBA(1, 0.2, 0.2); $0.unsung = RGBA(1, 1, 1); $0.outlineWidth = 8
                $0.shadow = RGBA(0, 0, 0, 1); $0.shadowBlur = 0; $0.shadowOffset = 7; $0.pop = 0.25; $0.fill = .word
            },
            preset("Candy") {
                $0.fontFamily = "Chalkboard SE"; $0.fontSize = 78
                $0.sung = RGBA(1, 0.4, 0.7); $0.unsung = RGBA(1, 0.92, 0.96); $0.outline = RGBA(0.5, 0.05, 0.3)
                $0.sungOutline = RGBA(0.5, 0.05, 0.3); $0.outlineWidth = 6
                $0.shadow = RGBA(0.5, 0.05, 0.3, 0.6); $0.shadowBlur = 4; $0.shadowOffset = 5; $0.pop = 0.2
            },
            preset("Chalk") {
                $0.fontFamily = "Chalkduster"; $0.bold = false; $0.fontSize = 70
                $0.sung = RGBA(1, 1, 1); $0.unsung = RGBA(1, 1, 1, 0.4); $0.outlineWidth = 0
                $0.shadow = RGBA(1, 1, 1, 0.35); $0.shadowBlur = 10; $0.shadowOffset = 0; $0.background = RGBA(0.12, 0.2, 0.16)
            },
            preset("Stadium") {
                $0.fontFamily = "Impact"; $0.bold = false; $0.uppercase = true; $0.fontSize = 88
                $0.sung = RGBA(1, 0.85, 0); $0.unsung = RGBA(1, 1, 1); $0.outline = RGBA(0.05, 0.1, 0.35)
                $0.sungOutline = RGBA(0.05, 0.1, 0.35); $0.outlineWidth = 7
                $0.shadow = RGBA(0, 0, 0, 0.8); $0.shadowBlur = 0; $0.shadowOffset = 6; $0.fill = .word
            },
            preset("Vintage") {
                $0.fontFamily = "Copperplate"; $0.fontSize = 66
                $0.sung = RGBA(0.95, 0.75, 0.45); $0.unsung = RGBA(0.95, 0.9, 0.8); $0.outline = RGBA(0.3, 0.2, 0.1)
                $0.sungOutline = RGBA(0.3, 0.2, 0.1); $0.outlineWidth = 2; $0.shadowBlur = 0; $0.shadowOffset = 0
                $0.box = true; $0.boxColor = RGBA(0.22, 0.13, 0.06, 0.75); $0.background = RGBA(0.16, 0.12, 0.08)
            },
            preset("Disco") {
                $0.fontFamily = "Avenir Next"; $0.uppercase = true; $0.fontSize = 76
                $0.sung = RGBA(1, 0.3, 0.9); $0.unsung = RGBA(0.45, 0.9, 1); $0.outline = RGBA(0.1, 0, 0.25)
                $0.sungOutline = RGBA(0.1, 0, 0.25); $0.outlineWidth = 3
                $0.shadow = RGBA(1, 1, 1, 0.7); $0.shadowBlur = 16; $0.shadowOffset = 0; $0.pop = 0.15; $0.fill = .word
            },
            preset("Glass") {
                $0.fontFamily = "Helvetica Neue"; $0.fontSize = 72
                $0.sung = RGBA(1, 1, 1); $0.unsung = RGBA(1, 1, 1, 0.5); $0.outlineWidth = 0
                $0.shadowBlur = 0; $0.shadowOffset = 0; $0.box = true; $0.boxColor = RGBA(1, 1, 1, 0.18)
                $0.highlight = RGBA(1, 1, 1, 0.3); $0.fill = .word
            },
            preset("Alert") {
                $0.fontFamily = "Helvetica Neue"; $0.uppercase = true; $0.fontSize = 72
                $0.sung = RGBA(1, 1, 1); $0.unsung = RGBA(1, 1, 1); $0.outlineWidth = 3
                $0.shadowBlur = 0; $0.shadowOffset = 0; $0.highlight = RGBA(0.9, 0.15, 0.2); $0.fill = .word; $0.pop = 0.08
            },
            preset("Horror") {
                $0.fontFamily = "Herculanum"; $0.bold = false; $0.fontSize = 80
                $0.sung = RGBA(0.75, 0, 0.05); $0.unsung = RGBA(0.7, 0.7, 0.68); $0.outline = RGBA(0, 0, 0)
                $0.sungOutline = RGBA(0.2, 0, 0); $0.outlineWidth = 3
                $0.shadow = RGBA(0.6, 0, 0, 0.9); $0.shadowBlur = 16; $0.shadowOffset = 3; $0.background = RGBA(0.05, 0.03, 0.03)
            },
        ]
    }()
}

/// Presets the user saved, in UserDefaults.
enum UserPresets {
    static let key = "userPresets"
    static func decode(_ data: Data) -> [Preset] { (try? JSONDecoder().decode([Preset].self, from: data)) ?? [] }
    static func encode(_ presets: [Preset]) -> Data { (try? JSONEncoder().encode(presets)) ?? Data() }
}
