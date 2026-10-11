import SwiftUI

/// The whole song on a scrolling, zoomable time axis: ruler, waveform and every word. Drag on the waveform to
/// scrub (you hear it), click a word to select it (⇧ for a range), drag a word to move it and drag its edges to
/// change where it starts and ends — the audio at the edge plays as you drag. Follows the playhead while playing.
struct SongTimeline: View {
    @Binding var lines: [Line]
    /// Points per second.
    @Binding var zoom: Double
    let selection: Set<Word.ID>
    let primary: Word.ID?
    let now: Double
    let duration: Double
    let isPlaying: Bool
    let waveform: [Float]
    let select: (Word.ID) -> Void
    let scrub: (Double) -> Void

    static let zoomRange = 15.0...1200.0
    private static let rulerHeight = 22.0
    private static let tileWidth = 1024.0

    private enum Handle { case start, end, move }
    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset = 0.0
    @State private var viewport = 0.0
    @State private var dragOrigin: Word?
    @State private var pinchBase: Double?

    private struct Item: Identifiable {
        let line: Int, index: Int, word: Word
        var id: Word.ID { word.id }
    }

    var body: some View {
        GeometryReader { geo in
            let track = geo.size.height - Self.rulerHeight
            let tiles = max(1, Int((duration * zoom / Self.tileWidth).rounded(.up)))
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    // Ruler and waveform in fixed-width tiles, made as they scroll into view.
                    LazyHStack(spacing: 0) {
                        ForEach(0..<tiles, id: \.self) { tile in
                            Canvas { ctx, size in draw(tile: tile, in: &ctx, size: size) }
                                .frame(width: Self.tileWidth, height: geo.size.height)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in scrub(max(0, g.location.x / zoom)) })

                    ForEach(items) { item in
                        wordView(item, height: track)
                            .frame(width: max(4, (item.word.end - item.word.start) * zoom), height: track)
                            .offset(x: item.word.start * zoom, y: Self.rulerHeight)
                    }

                    Rectangle().fill(.red).frame(width: 1.5, height: geo.size.height).offset(x: now * zoom - 0.75)
                        .allowsHitTesting(false)
                }
                .frame(width: max(geo.size.width, Double(tiles) * Self.tileWidth), height: geo.size.height, alignment: .topLeading)
            }
            .scrollIndicators(.visible)
            .scrollPosition($position)
            .onScrollGeometryChange(for: Double.self) { $0.contentOffset.x } action: { _, x in offset = x }
            .onAppear { viewport = geo.size.width }
            .onChange(of: geo.size.width) { viewport = geo.size.width }
        }
        .simultaneousGesture(MagnifyGesture()
            .onChanged { g in
                if pinchBase == nil { pinchBase = zoom }
                zoom = (pinchBase! * g.magnification).clamped(to: Self.zoomRange)
            }
            .onEnded { _ in pinchBase = nil })
        .onChange(of: zoom) { old, new in
            // Keep the time under the middle of the view where it is.
            let middle = (offset + viewport / 2) / old
            position.scrollTo(x: max(0, middle * new - viewport / 2))
        }
        .onChange(of: now) {
            // Follow the playhead: when it leaves the view, turn the page.
            guard isPlaying, dragOrigin == nil else { return }
            let x = now * zoom
            if x < offset || x > offset + viewport * 0.9 { position.scrollTo(x: max(0, x - viewport * 0.1)) }
        }
        .onChange(of: primary) {
            // Bring a word picked in the lyrics into view.
            guard let primary, let word = lines.lazy.flatMap(\.words).first(where: { $0.id == primary }) else { return }
            if word.start * zoom < offset || word.end * zoom > offset + viewport {
                position.scrollTo(x: max(0, word.start * zoom - viewport / 3))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("Word Timeline"))
    }

    private var items: [Item] {
        lines.enumerated().flatMap { l, line in line.words.enumerated().map { Item(line: l, index: $0, word: $1) } }
    }

    private func draw(tile: Int, in ctx: inout GraphicsContext, size: CGSize) {
        let start = Double(tile) * Self.tileWidth / zoom
        // Ruler: a labelled tick every `step` seconds (at least ~80 pt apart), four small ticks in between.
        let step = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60].first { $0 * zoom >= 80 } ?? 120
        let minor = step / 5
        var ticks = Path()
        for k in Int((start / minor).rounded(.down))...Int(((start + size.width / zoom) / minor).rounded(.up)) {
            let t = Double(k) * minor, x = (t - start) * zoom
            let major = k.isMultiple(of: 5)
            ticks.addRect(CGRect(x: x, y: major ? 12 : 17, width: 1, height: major ? 10 : 5))
            if major && t >= 0 {
                ctx.draw(Text(t.rulerLabel(step: step)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 3, y: 1), anchor: .topLeading)
            }
        }
        ctx.fill(ticks, with: .color(.secondary.opacity(0.6)))

        // Waveform: the loudest peak under each 2-point column.
        let top = Self.rulerHeight, height = size.height - top
        var wave = Path()
        for column in stride(from: 0.0, to: size.width, by: 2) {
            let a = Int((start + column / zoom) * 100), b = max(a + 1, Int((start + (column + 2) / zoom) * 100))
            guard a >= 0, a < waveform.count else { continue }
            let peak = waveform[a..<min(b, waveform.count)].max() ?? 0
            let h = max(1, Double(peak) * height * 0.9)
            wave.addRect(CGRect(x: column, y: top + (height - h) / 2, width: 1.2, height: h))
        }
        ctx.fill(wave, with: .color(.primary.opacity(0.45)))
    }

    private func wordView(_ item: Item, height: Double) -> some View {
        let selected = selection.contains(item.id), isPrimary = item.id == primary
        // Alternate lines get a slightly different tint, so where a line ends is visible at a glance.
        let tint = selected ? Color.accentColor.opacity(isPrimary ? 0.3 : 0.2)
            : (item.line.isMultiple(of: 2) ? Color.secondary.opacity(0.10) : Color.secondary.opacity(0.18))
        return Rectangle()
            .fill(tint)
            .overlay(alignment: .leading) {
                Rectangle().fill(selected ? Color.accentColor : Color.primary.opacity(0.35)).frame(width: selected ? 2 : 1)
            }
            .overlay {
                if selected { Rectangle().strokeBorder(Color.accentColor, lineWidth: isPrimary ? 2 : 1) }
            }
            .overlay(alignment: .leading) {
                Text(item.word.text)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 2)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(drag(item, .move))
            .onTapGesture { select(item.id) }
            .overlay(alignment: .leading) { edge(item, .start) }
            .overlay(alignment: .trailing) { edge(item, .end) }
            .accessibilityElement()
            .accessibilityLabel(item.word.text)
            .accessibilityValue("\(item.word.start.timecode) – \(item.word.end.timecode)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { select(item.id) }
    }

    private func edge(_ item: Item, _ handle: Handle) -> some View {
        Color.clear.frame(width: 8).contentShape(Rectangle())
            .pointerStyle(.frameResize(position: handle == .start ? .leading : .trailing))
            .gesture(drag(item, handle))
    }

    private func drag(_ item: Item, _ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                let (l, i) = (item.line, item.index)
                guard lines.indices.contains(l), lines[l].words.indices.contains(i) else { return }
                if dragOrigin == nil {
                    dragOrigin = lines[l].words[i]
                    if !selection.contains(item.id) { select(item.id) }
                }
                guard let o = dragOrigin else { return }
                let dt = g.translation.width / zoom
                // Neighbours across lines too, so words never overlap.
                let lo = i > 0 ? lines[l].words[i - 1].end : (l > 0 ? lines[l - 1].end : 0)
                let hi = i + 1 < lines[l].words.count ? lines[l].words[i + 1].start
                    : (l + 1 < lines.count ? lines[l + 1].start : .infinity)
                var w = lines[l].words[i]
                switch handle {
                case .start: w.start = min(max(lo, o.start + dt), w.end - 0.05)
                case .end: w.end = max(min(hi, o.end + dt), w.start + 0.05)
                case .move:
                    let d = min(max(dt, lo - o.start), hi - o.end)
                    (w.start, w.end) = (o.start + d, o.end + d)
                }
                lines[l].words[i] = w
                // Hear where the edge is: from the start, or the moment just before the end.
                scrub(handle == .end ? w.end - 0.15 : w.start)
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

private extension Double {
    /// 1:05 on whole-second steps, 1:05.5 below.
    func rulerLabel(step: Double) -> String {
        let t = (self * 10).rounded() / 10
        return step >= 1 ? String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
            : String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}
