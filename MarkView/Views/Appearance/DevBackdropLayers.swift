import AppKit
import QuartzCore

/// Git Flow and Typewriter: two scenes about writing and versioning work. Motion stays in the render server (Core Animation); there is
/// no display link and no SwiftUI frame timer. Neither scene draws document text: the typewriter writes bars shaped like words.
extension BackdropBuilder {
    // MARK: - Git Flow

    /// A commit graph that drifts left. One tile as wide as the window is laid out twice side by side; the pair slides by exactly one
    /// tile and starts again, and because every lane and every animation of the second tile equals the first, the restart is invisible.
    func gitFlow() -> [CALayer] {
        var random = BackdropRandom(seed: seed)
        let period = size.width
        let edge: CGFloat = 46
        let laneCount = min(5, max(3, Int(size.height / 150)))
        let main = (laneCount - 1) / 2
        // Lanes sit close together around the middle of the window (at most 105 points apart), so the curves between them are short.
        let spacing = min(105, size.height * 0.7 / CGFloat(laneCount - 1))
        func laneY(_ lane: Int) -> CGFloat { size.height / 2 + (CGFloat(laneCount - 1) / 2 - CGFloat(lane)) * spacing }
        let mainY = laneY(main)
        let branchTints = [colors.green, colors.purple, colors.orange, colors.cyan, colors.yellow]
        func tint(_ lane: Int) -> NSColor { lane == main ? colors.blue : branchTints[lane % branchTints.count] }

        // Branches leave the main lane, run along their own lane and come back (merge). Each one stays inside the tile.
        struct Branch { var lane: Int; var a, b, r: CGFloat }
        var branches: [Branch] = []
        for lane in 0..<laneCount where lane != main {
            let slots = detail >= 3 && period > 900 ? 2 : 1
            let slotWidth = (period - 2 * edge) / CGFloat(slots)
            for slot in 0..<slots {
                let start = edge + CGFloat(slot) * slotWidth
                let a = start + slotWidth * random.range(0.02, 0.22)
                let b = start + slotWidth * random.range(0.78, 0.98)
                let r = min(abs(laneY(lane) - mainY) * 0.8 + 30, (b - a - 70) / 2)
                if r >= 24 { branches.append(Branch(lane: lane, a: a, b: b, r: r)) }
            }
        }

        // Commits.
        var dots: [(x: CGFloat, lane: Int)] = []
        var x = edge + random.range(0, 24)
        while x <= period - edge {
            if !branches.contains(where: { abs($0.a - x) < 30 || abs($0.b - x) < 30 }) { dots.append((x, main)) }
            x += detail >= 3 ? random.range(44, 74) : random.range(58, 96)
        }
        for branch in branches {
            dots += [(branch.a, main), (branch.b, main), (branch.a + branch.r, branch.lane), (branch.b - branch.r, branch.lane)]
            var along = branch.a + branch.r + random.range(50, 80)
            while along < branch.b - branch.r - 40 {
                dots.append((along, branch.lane))
                along += random.range(56, 96)
            }
        }
        // Commits that send out a ring now and then, and the glow where a branch joins the main lane.
        struct Ping { var x: CGFloat; var lane: Int; var seconds: Double; var offset: Double }
        let pings: [Ping] = (0..<(4 + detail * 2)).compactMap { _ in
            guard !dots.isEmpty else { return nil }
            let dot = dots[random.int(dots.count)]
            return Ping(x: dot.x, lane: dot.lane, seconds: Double(random.range(3.2, 5.2)), offset: Double(random.range(0, 5)))
        }
        let flashes = branches.map { (branch: $0, seconds: Double(random.range(5, 9)), offset: Double(random.range(0, 9))) }

        func tile(offset: CGFloat) -> [CALayer] {
            var layers: [CALayer] = []
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: offset + x, y: y) }
            let mainPath = CGMutablePath()
            mainPath.move(to: point(0, mainY)); mainPath.addLine(to: point(period, mainY))
            let mainLine = shape(mainPath, stroke: colors.blue.withAlphaComponent(0.42 * colors.strength), width: 2.2)
            mainLine.lineCap = .butt
            layers.append(mainLine)
            for lane in 0..<laneCount where lane != main && branches.contains(where: { $0.lane == lane }) {
                let path = CGMutablePath()
                for branch in branches where branch.lane == lane {
                    let y = laneY(lane)
                    path.move(to: point(branch.a, mainY))
                    path.addCurve(to: point(branch.a + branch.r, y), control1: point(branch.a + branch.r * 0.6, mainY), control2: point(branch.a + branch.r * 0.4, y))
                    path.addLine(to: point(branch.b - branch.r, y))
                    path.addCurve(to: point(branch.b, mainY), control1: point(branch.b - branch.r * 0.4, y), control2: point(branch.b - branch.r * 0.6, mainY))
                }
                layers.append(shape(path, stroke: tint(lane).withAlphaComponent(0.36 * colors.strength), width: 1.7))
            }
            for lane in 0..<laneCount {
                let path = CGMutablePath()
                for dot in dots where dot.lane == lane {
                    let c = point(dot.x, laneY(lane))
                    path.addEllipse(in: CGRect(x: c.x - 4.6, y: c.y - 4.6, width: 9.2, height: 9.2))
                }
                if path.isEmpty { continue }
                layers.append(shape(path, stroke: tint(lane).withAlphaComponent(0.9 * colors.strength), fill: colors.background.withAlphaComponent(0.95), width: 1.8))
            }
            for item in flashes {
                let flash = glow(at: point(item.branch.b, mainY), radius: 24, tint: tint(item.branch.lane))
                if animated {
                    flash.opacity = 0
                    let pulse = CAKeyframeAnimation(keyPath: "opacity")
                    pulse.values = [0, 0.95, 0, 0]
                    pulse.keyTimes = [0, 0.06, 0.28, 1]
                    pulse.duration = item.seconds
                    pulse.timeOffset = item.offset
                    pulse.repeatCount = .infinity
                    pulse.isRemovedOnCompletion = false
                    flash.add(pulse, forKey: "merge")
                } else {
                    flash.opacity = 0.4
                }
                layers.append(flash)
            }
            for ping in pings {
                let ring = CAShapeLayer()
                ring.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
                ring.position = point(ping.x, laneY(ping.lane))
                ring.path = CGPath(ellipseIn: CGRect(x: 6, y: 6, width: 12, height: 12), transform: nil)
                ring.fillColor = nil
                ring.strokeColor = tint(ping.lane).withAlphaComponent(0.8 * colors.strength).cgColor
                ring.lineWidth = 1.5
                ring.contentsScale = scale
                if animated {
                    let grow = CABasicAnimation(keyPath: "transform.scale")
                    grow.fromValue = 0.6; grow.toValue = 2.3
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0.9; fade.toValue = 0
                    let group = CAAnimationGroup()
                    group.animations = [grow, fade]
                    group.duration = ping.seconds
                    group.timeOffset = ping.offset
                    group.repeatCount = .infinity
                    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    group.isRemovedOnCompletion = false
                    ring.add(group, forKey: "commit")
                } else {
                    ring.opacity = 0.45
                    ring.transform = CATransform3DMakeScale(1.4, 1.4, 1)
                }
                layers.append(ring)
            }
            return layers
        }

        let container = CALayer()
        for copy in 0..<2 { for layer in tile(offset: CGFloat(copy) * period) { container.addSublayer(layer) } }
        if animated {
            container.add(basic("position.x", from: 0, to: -Double(period), seconds: Double(period) / 26), forKey: "drift")
        }
        return [container]
    }

    // MARK: - Typewriter

    /// One or more pages of Markdown being written, in bars shaped like words: headings, paragraphs, bullets and a code block. A caret
    /// types them line by line, the page rests, fades and starts again.
    func typewriter() -> [CALayer] {
        var random = BackdropRandom(seed: seed)
        let pitch: CGFloat = 30
        let lineCount = max(6, min(Int((size.height - 90) / pitch), 11 + 2 * detail))
        // The action tiles take the middle 760 points of the welcome screen and hide what is behind them, so the pages are written in the
        // margins on both sides (one or two pages a side, as wide as the margin allows). A window with no margin gets one page behind the tiles.
        let side = (size.width - 760) / 2
        var pages: [(left: CGFloat, width: CGFloat)] = []
        if side >= 110 {
            let perSide = side >= 1000 ? 2 : 1
            let slot = side / CGFloat(perSide)
            let width = min(520, max(190, slot - 36))
            for index in 0..<perSide {
                let left = max(18, slot * (CGFloat(index) + 0.5) - width / 2)
                pages.append((left, width))
            }
            pages += pages.map { (size.width - $0.left - $0.width, $0.width) }
        } else {
            let width = min(520, size.width - 70)
            pages = [((size.width - width) / 2, width)]
        }
        var layers: [CALayer] = []
        for page in pages {
            layers += typewriterPage(left: page.left, pageWidth: page.width, pitch: pitch, lineCount: lineCount, random: &random)
        }
        return layers
    }

    private enum TypeKind { case heading, sub, paragraph, bullet, code, fence, blank }

    /// A piece of one line that is written in one go: a run of words in one colour (or one dot).
    private struct TypePart {
        var words: [(from: CGFloat, to: CGFloat)]
        var y: CGFloat
        var width: CGFloat
        var color: NSColor
        var isDot = false
        var length: CGFloat { isDot ? 0.01 : words.reduce(0) { $0 + ($1.to - $1.from) } }

        /// The x of the caret once `drawn` points of the part are written (gaps between words are jumped).
        func caretX(after drawn: CGFloat) -> CGFloat {
            if isDot { return (words.first?.from ?? 0) + (drawn > 0 ? 8 : -6) }
            var left = drawn
            for word in words {
                let size = word.to - word.from
                if left <= size { return word.from + left + 3 }
                left -= size
            }
            return (words.last?.to ?? 0) + 3
        }
    }

    private func typewriterPage(left: CGFloat, pageWidth: CGFloat, pitch: CGFloat, lineCount: Int, random: inout BackdropRandom) -> [CALayer] {
        let s = colors.strength
        // The rows of the page: which kind of line each one is.
        var rows: [(kind: TypeKind, flag: Bool)] = [(.heading, false), (.blank, false)]
        var codeRows: ClosedRange<Int>?
        var block = 0
        while rows.count < lineCount {
            switch block % 4 {
            case 0: let n = 2 + random.int(2); rows += (0..<n).map { (.paragraph, $0 == n - 1) }
            case 1: rows.append((.sub, false)); let n = 3 + random.int(2); rows += (0..<n).map { _ in (.bullet, false) }
            case 2:
                let n = 3 + random.int(2); let first = rows.count
                rows += [(.fence, true)] + (0..<n).map { _ in (.code, false) } + [(.fence, false)]
                if codeRows == nil { codeRows = first...(rows.count - 1) }
            default: let n = 2 + random.int(2); rows += (0..<n).map { (.paragraph, $0 == n - 1) }
            }
            rows.append((.blank, false))
            block += 1
        }
        rows = Array(rows.prefix(lineCount))
        if let range = codeRows { codeRows = range.lowerBound <= lineCount - 2 ? range.lowerBound...min(range.upperBound, lineCount - 1) : nil }

        func words(from start: CGFloat, length: CGFloat) -> [(from: CGFloat, to: CGFloat)] {
            var result: [(from: CGFloat, to: CGFloat)] = []
            var x = start
            let end = min(start + max(length, 14), left + pageWidth)
            while x < end - 10 {
                let word = min(random.range(14, 56), end - x)
                result.append((x, x + word))
                x += word + random.range(11, 15)
            }
            return result.isEmpty ? [(start, start + 14)] : result
        }
        func y(_ row: Int) -> CGFloat { size.height / 2 + (CGFloat(lineCount) / 2 - CGFloat(row) - 0.5) * pitch }

        var lines: [[TypePart]] = []
        for (index, row) in rows.enumerated() {
            let y = y(index)
            switch row.kind {
            case .heading:
                lines.append([TypePart(words: [(left, left + 13)], y: y, width: 10, color: colors.blue.withAlphaComponent(0.8 * s)),
                              TypePart(words: words(from: left + 28, length: pageWidth * random.range(0.35, 0.6)), y: y, width: 10, color: colors.bright.withAlphaComponent(0.55 * s))])
            case .sub:
                lines.append([TypePart(words: [(left, left + 24)], y: y, width: 7, color: colors.blue.withAlphaComponent(0.6 * s)),
                              TypePart(words: words(from: left + 36, length: pageWidth * random.range(0.28, 0.45)), y: y, width: 8, color: colors.bright.withAlphaComponent(0.45 * s))])
            case .paragraph:
                let length = row.flag ? pageWidth * random.range(0.25, 0.65) : pageWidth * random.range(0.9, 1)
                lines.append([TypePart(words: words(from: left, length: length), y: y, width: 6.5, color: colors.dim.withAlphaComponent(0.5 * s))])
            case .bullet:
                lines.append([TypePart(words: [(left + 10, left + 10)], y: y, width: 8, color: colors.cyan.withAlphaComponent(0.8 * s), isDot: true),
                              TypePart(words: words(from: left + 28, length: pageWidth * random.range(0.35, 0.8) - 28), y: y, width: 6.5, color: colors.dim.withAlphaComponent(0.5 * s))])
            case .fence:
                var parts = [TypePart(words: [(left, left + 26)], y: y, width: 6, color: colors.orange.withAlphaComponent(0.55 * s))]
                if row.flag { parts.append(TypePart(words: [(left + 38, left + 38 + random.range(30, 46))], y: y, width: 6, color: colors.purple.withAlphaComponent(0.6 * s))) }
                lines.append(parts)
            case .code:
                var x = left + 14 + CGFloat(random.int(3)) * min(20, pageWidth / 12)
                var parts: [TypePart] = []
                let palette: [(NSColor, ClosedRange<CGFloat>)] = [(colors.purple, 24...40), (colors.cyan, 40...110), (random.chance(0.5) ? colors.green : colors.dim, 30...90)]
                for (color, range) in palette.prefix(2 + random.int(2)) {
                    if x > left + pageWidth - 36 { break }
                    let length = random.range(range.lowerBound, range.upperBound)
                    let part = TypePart(words: words(from: x, length: length), y: y, width: 6, color: color.withAlphaComponent(0.6 * s))
                    parts.append(part)
                    x = (part.words.last?.to ?? x) + 12
                }
                lines.append(parts)
            case .blank:
                lines.append([])
            }
        }

        // The timeline of one cycle: every part has a start, a duration and a number of key presses.
        struct Timed { var layer: CAShapeLayer; var part: TypePart; var start: Double; var duration: Double; var steps: Int }
        var timed: [Timed] = []
        var time = Double(random.range(0.3, 0.7))
        let speed = Double(random.range(190, 260))
        var partLayers: [CAShapeLayer] = []
        for line in lines {
            if line.isEmpty { time += 0.5; continue }
            for part in line {
                let path = CGMutablePath()
                for word in part.words { path.move(to: CGPoint(x: word.from, y: part.y)); path.addLine(to: CGPoint(x: max(word.to, word.from + 0.01), y: part.y)) }
                let layer = shape(path, stroke: part.color, width: part.width)
                partLayers.append(layer)
                let duration = max(0.1, Double(part.length) / speed)
                timed.append(Timed(layer: layer, part: part, start: time, duration: duration, steps: part.isDot ? 1 : max(1, Int((part.length / 7.5).rounded()))))
                time += duration + 0.04
            }
            time += Double(random.range(0.1, 0.28))
        }
        let typingEnd = time
        let hold = Double(random.range(4.5, 6.5)), fade = 1.6, rest = 0.9
        let cycle = typingEnd + hold + fade + rest
        // Drawn for both pictures, so that the still and the moving scene take the same numbers from the generator.
        let head = Double(random.range(0.15, 0.5))
        let offset = animated ? typingEnd * head : 0

        // The page: an optional code panel under the bars.
        let page = CALayer()
        if let range = codeRows {
            let rect = CGRect(x: left - 14, y: y(range.upperBound) - pitch * 0.45, width: pageWidth + 28, height: CGFloat(range.count) * pitch - pitch * 0.1)
            let panel = shape(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil), stroke: colors.dim.withAlphaComponent(0.2 * s),
                              fill: colors.dim.withAlphaComponent(0.07 * s), width: 1)
            if animated, let first = timed.first(where: { abs($0.part.y - y(range.lowerBound)) < 1 }) {
                panel.opacity = 0
                let appear = CABasicAnimation(keyPath: "opacity")
                appear.fromValue = 0; appear.toValue = 1; appear.duration = 0.4; appear.beginTime = max(0, first.start - 0.3); appear.fillMode = .forwards
                panel.add(cycled([appear], cycle: cycle, offset: offset), forKey: "panel")
            }
            page.addSublayer(panel)
        }

        // The caret: a bar that follows the key presses. It is a root layer of its own (a blinking child inside), so that it can move.
        let caretHeight = pitch * 0.62
        let caret = CALayer()
        caret.bounds = CGRect(x: 0, y: 0, width: 2.6, height: caretHeight)
        let blinker = CALayer()
        blinker.bounds = caret.bounds
        blinker.position = CGPoint(x: 1.3, y: caretHeight / 2)
        blinker.backgroundColor = colors.bright.withAlphaComponent(0.85 * colors.strength).cgColor
        blinker.cornerRadius = 1.3
        caret.addSublayer(blinker)
        let startPoint = timed.first.map { CGPoint(x: $0.part.caretX(after: 0), y: $0.part.y) } ?? .zero
        let endPoint = timed.last.map { CGPoint(x: $0.part.caretX(after: $0.part.length), y: $0.part.y) } ?? .zero
        caret.position = animated ? startPoint : endPoint

        var caretMoves: [CAAnimation] = []
        for item in timed {
            page.addSublayer(item.layer)
            guard animated else { continue }
            item.layer.strokeEnd = 0
            let type = CAKeyframeAnimation(keyPath: "strokeEnd")
            type.values = (0...item.steps).map { Double($0) / Double(item.steps) }
            type.calculationMode = .discrete
            type.duration = item.duration
            type.beginTime = item.start
            type.fillMode = .forwards
            item.layer.add(cycled([type], cycle: cycle, offset: offset), forKey: "type")
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = (0...item.steps).map { step in
                NSValue(point: NSPoint(x: item.part.caretX(after: item.part.length * CGFloat(step) / CGFloat(item.steps)), y: item.part.y))
            }
            move.calculationMode = .discrete
            move.duration = item.duration
            move.beginTime = item.start
            move.fillMode = .forwards
            caretMoves.append(move)
        }
        if animated {
            caret.add(cycled(caretMoves, cycle: cycle, offset: offset), forKey: "caret")
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1.0, 0.1]
            blink.calculationMode = .discrete
            blink.duration = 1.1
            blink.repeatCount = .infinity
            blink.isRemovedOnCompletion = false
            blinker.add(blink, forKey: "blink")
            for target in [page, caret] {
                let fadeOut = CAKeyframeAnimation(keyPath: "opacity")
                fadeOut.values = [1, 1, 0, 0]
                fadeOut.keyTimes = [0, NSNumber(value: (typingEnd + hold) / cycle), NSNumber(value: (typingEnd + hold + fade) / cycle), 1]
                fadeOut.duration = cycle
                fadeOut.timeOffset = offset
                fadeOut.repeatCount = .infinity
                fadeOut.isRemovedOnCompletion = false
                target.add(fadeOut, forKey: "page")
            }
        }
        return [page, caret]
    }

    /// The animations of one page cycle, run as one group so that all of them repeat together and the page starts again clean.
    private func cycled(_ animations: [CAAnimation], cycle: Double, offset: Double) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = cycle
        group.timeOffset = offset
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        return group
    }
}

// MARK: - Registrations (AR-34)

final class GitFlowBackdrop: BackdropDrawing {
    static let descriptor = BackdropDescriptor.scene("gitflow", title: "Git Flow", symbol: "arrow.triangle.branch", order: 100)
    static func layers(_ builder: BackdropBuilder) -> [CALayer] { builder.gitFlow() }
}

final class TypewriterBackdrop: BackdropDrawing {
    static let descriptor = BackdropDescriptor.scene("typewriter", title: "Typewriter", symbol: "text.cursor", order: 110)
    static func layers(_ builder: BackdropBuilder) -> [CALayer] { builder.typewriter() }
}
