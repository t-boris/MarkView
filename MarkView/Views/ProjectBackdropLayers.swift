import AppKit
import QuartzCore

/// Five scenes built from vector layers. Motion stays in the render server and uses no display-link or SwiftUI frame timer.
extension BackdropBuilder {
    private var tints: [NSColor] { [colors.cyan, colors.purple, colors.green, colors.blue, colors.orange] }

    private func shape(_ path: CGPath, stroke: NSColor?, fill: NSColor? = nil, width: CGFloat = 1) -> CAShapeLayer {
        let result = CAShapeLayer()
        result.path = path
        result.strokeColor = stroke?.cgColor
        result.fillColor = fill?.cgColor
        result.lineWidth = width
        result.lineCap = .round
        result.lineJoin = .round
        result.contentsScale = scale
        return result
    }

    private func glow(at point: CGPoint, radius: CGFloat, tint: NSColor) -> CALayer {
        let result = CAGradientLayer()
        result.type = .radial
        result.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        result.position = point
        result.colors = [tint.withAlphaComponent(0.8 * colors.strength).cgColor, tint.withAlphaComponent(0).cgColor]
        result.startPoint = CGPoint(x: 0.5, y: 0.5)
        result.endPoint = CGPoint(x: 1, y: 1)
        return result
    }

    private func follow(_ path: CGPath, seconds: Double, phase: Double, rotate: Bool = false) -> CAKeyframeAnimation {
        let result = CAKeyframeAnimation(keyPath: "position")
        result.path = path
        result.calculationMode = .paced
        if rotate { result.rotationMode = .rotateAuto }
        result.duration = seconds
        result.timeOffset = phase * seconds
        result.repeatCount = .infinity
        result.isRemovedOnCompletion = false
        return result
    }

    func orbit() -> [CALayer] {
        var random = BackdropRandom(seed: seed)
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.57)
        var layers: [CALayer] = []
        for _ in 0..<65 {
            let star = glow(at: CGPoint(x: random.unit() * size.width, y: random.unit() * size.height), radius: random.range(1, 2.8), tint: colors.bright)
            layers.append(star)
        }
        let core = glow(at: center, radius: min(size.width, size.height) * 0.19, tint: colors.purple)
        if animated { core.add(basic("transform.scale", from: 0.75, to: 1.2, seconds: 8, reverses: true, eased: true), forKey: "stellar-breath") }
        layers.append(core)
        for index in 0..<(5 + min(3, max(0, detail - 1))) {
            let radius = CGFloat(index + 1) * min(size.width, size.height) * 0.105
            let rect = CGRect(x: center.x - radius * 1.25, y: center.y - radius * 0.55, width: radius * 2.5, height: radius * 1.1)
            var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -0.32).translatedBy(x: -center.x, y: -center.y)
            let path = CGPath(ellipseIn: rect, transform: &transform)
            let ring = shape(path, stroke: tints[index % tints.count].withAlphaComponent(0.30 * colors.strength))
            ring.lineDashPattern = index % 2 == 0 ? [3, 8] : nil
            layers.append(ring)
            let phase = Double(random.unit())
            let angle = CGFloat(phase) * 2 * .pi
            let point = CGPoint(x: center.x + radius * 1.25 * cos(angle), y: center.y + radius * 0.55 * sin(angle)).applying(transform)
            let planet = glow(at: point, radius: random.range(12, 21), tint: tints[index % tints.count])
            let dot = shape(CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 8, height: 8), transform: nil), stroke: nil, fill: colors.bright.withAlphaComponent(0.9))
            dot.position = CGPoint(x: planet.bounds.midX - 4, y: planet.bounds.midY - 4)
            planet.addSublayer(dot)
            if animated { planet.add(follow(path, seconds: Double(20 + index * 7), phase: phase), forKey: "orbit") }
            layers.append(planet)
        }
        return layers
    }

    func blueprint() -> [CALayer] {
        var random = BackdropRandom(seed: seed)
        let grid = CGMutablePath()
        let spacing = max(40, min(size.width, size.height) / 14)
        for x in stride(from: CGFloat(0), through: size.width, by: spacing) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
        for y in stride(from: CGFloat(0), through: size.height, by: spacing) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
        var layers: [CALayer] = [shape(grid, stroke: colors.blue.withAlphaComponent(0.14 * colors.strength))]
        let positions: [CGPoint] = [.init(x: 0.12, y: 0.3), .init(x: 0.32, y: 0.78), .init(x: 0.53, y: 0.25), .init(x: 0.74, y: 0.72), .init(x: 0.91, y: 0.32)]
        let width = min(150, max(65, size.width * 0.13)), height = width * 1.95
        for (index, position) in positions.enumerated() {
            let center = CGPoint(x: position.x * size.width, y: position.y * size.height)
            let phone = layer(frame: center, width: width, height: height)
            let outline = CGPath(roundedRect: phone.bounds.insetBy(dx: 1, dy: 1), cornerWidth: width * 0.14, cornerHeight: width * 0.14, transform: nil)
            phone.addSublayer(shape(outline, stroke: colors.cyan.withAlphaComponent(0.55 * colors.strength), fill: colors.blue.withAlphaComponent(0.07), width: 1.5))
            let notch = CGPath(roundedRect: CGRect(x: width * 0.35, y: height - 14, width: width * 0.3, height: 4), cornerWidth: 2, cornerHeight: 2, transform: nil)
            phone.addSublayer(shape(notch, stroke: nil, fill: colors.cyan.withAlphaComponent(0.6)))
            for row in 0..<4 {
                let rect = CGRect(x: 12, y: 20 + CGFloat(row) * (height - 55) / 4, width: width - 24, height: (height - 75) / 4)
                let card = shape(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil), stroke: tints[(row + index) % tints.count].withAlphaComponent(0.35), fill: colors.blue.withAlphaComponent(0.08))
                if animated { card.add(basic("opacity", from: 0.35, to: 1, seconds: 2.4, offset: Double(row) * 0.6, reverses: true), forKey: "assemble") }
                phone.addSublayer(card)
            }
            let scan = glow(at: CGPoint(x: width / 2, y: height / 2), radius: width * 0.65, tint: colors.cyan)
            scan.bounds.size.height = 16
            scan.opacity = 0.6
            if animated { scan.add(basic("position.y", from: 16, to: Double(height - 16), seconds: 4 + Double(index), offset: Double(index), reverses: true), forKey: "scan") }
            phone.addSublayer(scan)
            let floatSeconds = Double(random.range(4, 7))
            if animated { phone.add(basic("position.y", from: Double(center.y - 8), to: Double(center.y + 8), seconds: floatSeconds, offset: Double(index), reverses: true, eased: true), forKey: "float") }
            layers.append(phone)
        }
        return layers
    }

    func circuit() -> [CALayer] {
        var random = BackdropRandom(seed: seed)
        var layers: [CALayer] = []
        let columns = max(3, min(8, Int(size.width / 180))), rows = max(3, min(6, Int(size.height / 180)))
        var nodes: [CGPoint] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: (CGFloat(column) + 0.5) * size.width / CGFloat(columns), y: (CGFloat(row) + 0.5) * size.height / CGFloat(rows))
                nodes.append(point)
                let chip = shape(CGPath(roundedRect: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28), cornerWidth: 4, cornerHeight: 4, transform: nil), stroke: colors.cyan.withAlphaComponent(0.4), fill: colors.background.withAlphaComponent(0.75))
                let pins = CGMutablePath()
                for offset in [-8.0, 0, 8] {
                    pins.move(to: CGPoint(x: point.x + offset, y: point.y - 20)); pins.addLine(to: CGPoint(x: point.x + offset, y: point.y + 20))
                    pins.move(to: CGPoint(x: point.x - 20, y: point.y + offset)); pins.addLine(to: CGPoint(x: point.x + 20, y: point.y + offset))
                }
                layers += [shape(pins, stroke: colors.blue.withAlphaComponent(0.3)), chip]
            }
        }
        for index in 0..<(12 + detail * 3) {
            let from = nodes[random.int(nodes.count)], to = nodes[random.int(nodes.count)]
            if from == to { continue }
            let middle = (from.x + to.x) / 2 + random.range(-22, 22)
            let path = CGMutablePath(); path.move(to: from)
            path.addLine(to: CGPoint(x: middle, y: from.y)); path.addLine(to: CGPoint(x: middle, y: to.y)); path.addLine(to: to)
            let tint = tints[index % tints.count]
            layers.append(shape(path, stroke: tint.withAlphaComponent(0.25 * colors.strength), width: 1.5))
            let phase = Double(random.unit())
            let spark = glow(at: from, radius: 12, tint: tint)
            let travel = Double(random.range(3, 8))
            if animated { spark.add(follow(path, seconds: travel, phase: phase), forKey: "packet") }
            layers.append(spark)
        }
        return layers
    }

    func garden() -> [CALayer] {
        var random = BackdropRandom(seed: seed)
        var layers: [CALayer] = []
        for index in 0..<(9 + detail) {
            let base = CGPoint(x: (CGFloat(index) + 0.5) * size.width / CGFloat(9 + detail), y: -10)
            let height = size.height * random.range(0.25, 0.8), sway = random.range(-50, 50)
            let stem = CGMutablePath(); stem.move(to: base)
            stem.addCurve(to: CGPoint(x: base.x + sway, y: height), control1: CGPoint(x: base.x - 35, y: height * 0.3), control2: CGPoint(x: base.x + 35, y: height * 0.7))
            let stalk = shape(stem, stroke: colors.green.withAlphaComponent(0.55 * colors.strength), width: 1.5)
            let growSeconds = Double(random.range(9, 15))
            if animated { stalk.add(basic("opacity", from: 0.45, to: 1, seconds: growSeconds, offset: Double(index), reverses: true, eased: true), forKey: "grow") }
            layers.append(stalk)
            for branch in 1...5 {
                let fraction = CGFloat(branch) / 6
                let u = 1 - fraction, t = fraction
                let point = CGPoint(x: u * u * u * base.x + 3 * u * u * t * (base.x - 35) + 3 * u * t * t * (base.x + 35) + t * t * t * (base.x + sway),
                                    y: u * u * u * base.y + 3 * u * u * t * height * 0.3 + 3 * u * t * t * height * 0.7 + t * t * t * height)
                let direction: CGFloat = branch % 2 == 0 ? 1 : -1
                let leaf = layer(frame: point, width: 40, height: 22)
                leaf.anchorPoint = .zero
                let path = CGMutablePath(); path.move(to: CGPoint(x: 0, y: 0))
                path.addQuadCurve(to: CGPoint(x: 40, y: 22), control: CGPoint(x: 5, y: 34))
                path.addQuadCurve(to: .zero, control: CGPoint(x: 32, y: -8))
                leaf.addSublayer(shape(path, stroke: colors.green.withAlphaComponent(0.4), fill: (branch % 3 == 0 ? colors.cyan : colors.green).withAlphaComponent(0.16 * colors.strength)))
                leaf.transform = CATransform3DMakeRotation(direction > 0 ? 0.15 : 2.6, 0, 0, 1)
                let swaySeconds = Double(random.range(3, 5))
                if animated { leaf.add(basic("transform.rotation.z", from: direction > 0 ? -0.1 : 2.4, to: direction > 0 ? 0.35 : 2.85, seconds: swaySeconds, offset: Double(index), reverses: true, eased: true), forKey: "sway") }
                if animated { leaf.add(basic("transform.scale", from: 0.75, to: 1.08, seconds: growSeconds, offset: Double(index), reverses: true, eased: true), forKey: "unfurl") }
                layers.append(leaf)
            }
            let bud = glow(at: CGPoint(x: base.x + sway, y: height), radius: 15, tint: colors.orange)
            if animated { bud.add(basic("opacity", from: 0.3, to: 0.85, seconds: 3, offset: Double(index), reverses: true), forKey: "bloom") }
            layers.append(bud)
        }
        for _ in 0..<25 {
            let point = CGPoint(x: random.unit() * size.width, y: random.unit() * size.height)
            let spore = glow(at: point, radius: random.range(2, 5), tint: colors.yellow)
            let driftSeconds = Double(random.range(4, 8)), driftOffset = Double(random.range(0, 8))
            if animated { spore.add(basic("position.y", from: Double(point.y - 30), to: Double(point.y + 30), seconds: driftSeconds, offset: driftOffset, reverses: true), forKey: "drift") }
            layers.append(spore)
        }
        return layers
    }

    func launch() -> [CALayer] {
        var random = BackdropRandom(seed: seed)
        var layers: [CALayer] = []
        for _ in 0..<55 {
            let point = CGPoint(x: random.unit() * size.width, y: random.unit() * size.height)
            let star = glow(at: point, radius: random.range(1, 3), tint: colors.bright)
            let starSeconds = Double(random.range(3, 6)), starOffset = Double(random.range(0, 6))
            if animated { star.add(basic("position.y", from: Double(point.y + 35), to: Double(point.y - 35), seconds: starSeconds, offset: starOffset, reverses: true), forKey: "starlight") }
            layers.append(star)
        }
        for index in 0..<(3 + min(3, detail)) {
            let fraction = CGFloat(index + 1) / CGFloat(4 + min(3, detail))
            let phase = Double(random.unit())
            let from = CGPoint(x: fraction * size.width - size.width * 0.08, y: -120)
            let to = CGPoint(x: from.x + size.width * 0.16, y: size.height + 120)
            let rocket = layer(frame: CGPoint(x: from.x + (to.x - from.x) * phase, y: from.y + (to.y - from.y) * phase), width: 40, height: 100)
            let body = CGMutablePath(); body.move(to: CGPoint(x: 20, y: 96))
            body.addCurve(to: CGPoint(x: 32, y: 42), control1: CGPoint(x: 35, y: 80), control2: CGPoint(x: 37, y: 55))
            body.addLine(to: CGPoint(x: 8, y: 42))
            body.addCurve(to: CGPoint(x: 20, y: 96), control1: CGPoint(x: 3, y: 55), control2: CGPoint(x: 5, y: 80))
            body.closeSubpath()
            let fins = CGMutablePath(); fins.move(to: CGPoint(x: 8, y: 57)); fins.addLines(between: [.init(x: 0, y: 32), .init(x: 12, y: 42), .init(x: 28, y: 42), .init(x: 40, y: 32), .init(x: 32, y: 57)])
            rocket.addSublayer(shape(fins, stroke: colors.cyan.withAlphaComponent(0.7), fill: colors.blue.withAlphaComponent(0.4)))
            rocket.addSublayer(shape(body, stroke: colors.cyan.withAlphaComponent(0.8), fill: colors.bright.withAlphaComponent(colors.isDark ? 0.25 : 0.1), width: 1.5))
            rocket.addSublayer(shape(CGPath(ellipseIn: CGRect(x: 14, y: 65, width: 12, height: 12), transform: nil), stroke: colors.cyan, fill: colors.blue.withAlphaComponent(0.5)))
            let flame = glow(at: CGPoint(x: 20, y: 29), radius: 19, tint: colors.orange)
            flame.bounds.size.height = 54
            if animated { flame.add(basic("transform.scale.y", from: 0.6, to: 1.3, seconds: 0.3, offset: phase, reverses: true), forKey: "thrust") }
            rocket.addSublayer(flame)
            rocket.transform = CATransform3DMakeRotation(-0.13, 0, 0, 1)
            let path = CGMutablePath(); path.move(to: from); path.addLine(to: to)
            let flightSeconds = Double(random.range(17, 25))
            if animated { rocket.add(follow(path, seconds: flightSeconds, phase: phase), forKey: "liftoff") }
            layers.append(rocket)
        }
        return layers
    }
}
