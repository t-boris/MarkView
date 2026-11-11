import AppKit
import QuartzCore

/// The colours a backdrop draws with, taken from the window's theme (REQ-003: a backdrop follows the theme, dark or light).
struct BackdropColors: Equatable {
    var background, bright, dim: NSColor
    var green, cyan, purple, blue, orange, red, yellow: NSColor
    var isDark: Bool

    init(_ palette: AppPalette) {
        let model = palette.model
        background = NSColor(model.bg); bright = NSColor(model.textBright); dim = NSColor(model.textDim)
        green = NSColor(model.green); cyan = NSColor(model.cyan); purple = NSColor(model.purple); blue = NSColor(model.blue)
        orange = NSColor(model.orange); red = NSColor(model.red); yellow = NSColor(model.yellow)
        isDark = model.isDark
    }

    /// How strongly light is drawn: light on a dark window is vivid, on a light window it has to stay quiet.
    var strength: CGFloat { isDark ? 0.9 : 0.7 }
}

/// Turns a scene into Core Animation layers (DEC-001). Every motion is an animation the render server runs, so the main thread
/// does nothing per frame. With `animated` false (Reduce Motion, or a still picture for a check) no animation is added and each layer
/// stands where the scene starts it.
struct BackdropBuilder {
    let size: CGSize
    let colors: BackdropColors
    let scale: CGFloat
    let animated: Bool
    let seed: UInt64
    var detail: Int = 1

    func layers(for kind: WelcomeBackdrop) -> [CALayer] {
        guard size.width >= 40, size.height >= 40 else { return [] }
        switch kind {
        case .matrix: return matrix()
        case .aurora: return aurora()
        case .bugs: return bugs()
        case .network: return network()
        case .orbit: return orbit()
        case .blueprint: return blueprint()
        case .circuit: return circuit()
        case .garden: return garden()
        case .launch: return launch()
        case .project, .shuffle, .off: return []
        }
    }

    // MARK: - Animation helpers

    /// `offset` starts the animation part-way along, so layers that share a duration do not move together.
    func basic(_ keyPath: String, from: Double, to: Double, seconds: Double, offset: Double = 0,
                       reverses: Bool = false, eased: Bool = false) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = seconds
        animation.timeOffset = offset
        animation.autoreverses = reverses
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: eased ? .easeInEaseOut : .linear)
        animation.isRemovedOnCompletion = false
        return animation
    }

    func layer(frame center: CGPoint, width: CGFloat, height: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        layer.position = center
        layer.contentsScale = scale
        return layer
    }

    // MARK: - Matrix rain

    private static let matrixCell = CGSize(width: 16, height: 19)

    private func matrix() -> [CALayer] {
        let cell = Self.matrixCell
        let scene = MatrixScene.make(size: size, cell: cell, seed: seed)
        let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
        let images: [[CGImage?]] = scene.strips.map { variants in
            variants.map { Self.stripImage(glyphs: $0, cell: cell, font: font, colors: colors, scale: scale) }
        }
        return scene.columns.map { column in
            let height = scene.stripHeight(column)
            let strip = layer(frame: CGPoint(x: column.x + cell.width / 2, y: scene.initialCenterY(column)), width: cell.width, height: height)
            let variants = images[column.lengthIndex]
            strip.contents = variants[column.variantOrder[0]]
            guard animated else { return strip }
            let fall = scene.fallSeconds(column)
            strip.add(basic("position.y", from: Double(scene.startCenterY(column)), to: Double(scene.endCenterY(column)),
                            seconds: fall, offset: Double(column.phase) * fall), forKey: "fall")
            // The symbols of a strip change a few at a time while it falls.
            let flicker = CAKeyframeAnimation(keyPath: "contents")
            flicker.values = column.variantOrder.map { variants[$0] as Any }
            flicker.calculationMode = .discrete
            flicker.duration = column.variantSeconds * Double(column.variantOrder.count)
            flicker.timeOffset = Double(column.phase) * flicker.duration
            flicker.repeatCount = .infinity
            flicker.isRemovedOnCompletion = false
            strip.add(flicker, forKey: "flicker")
            return strip
        }
    }

    /// One strip of symbols as an image: the tail (first symbol, drawn at the top) is clear, the head (last, at the bottom) is bright
    /// with a glow. The layer falls downwards, so the head leads.
    static func stripImage(glyphs: [Character], cell: CGSize, font: NSFont, colors: BackdropColors, scale: CGFloat) -> CGImage? {
        let width = Int((cell.width * scale).rounded(.up)), height = Int((cell.height * CGFloat(glyphs.count) * scale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let glow = NSShadow()
        glow.shadowBlurRadius = 7
        glow.shadowOffset = .zero
        glow.shadowColor = colors.green.withAlphaComponent(0.9)
        let last = glyphs.count - 1
        for (index, glyph) in glyphs.enumerated() {
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if index == last {
                attributes[.foregroundColor] = colors.bright
                attributes[.shadow] = glow
            } else if index == last - 1 {
                attributes[.foregroundColor] = colors.green.blended(withFraction: 0.4, of: colors.bright) ?? colors.green
            } else {
                let fraction = CGFloat(index) / CGFloat(max(last, 1))
                attributes[.foregroundColor] = colors.green.withAlphaComponent(pow(fraction, 1.7) * colors.strength)
            }
            let text = NSAttributedString(string: String(glyph), attributes: attributes)
            let extent = text.size()
            text.draw(at: NSPoint(x: (cell.width - extent.width) / 2,
                                  y: CGFloat(glyphs.count - 1 - index) * cell.height + (cell.height - extent.height) / 2))
        }
        return context.makeImage()
    }

    // MARK: - Aurora

    private func aurora() -> [CALayer] {
        let scene = AuroraScene.make(seed: seed)
        let tints = [colors.green, colors.cyan, colors.purple, colors.blue]
        var layers: [CALayer] = []
        let strength = colors.strength
        for star in scene.stars {
            let dot = layer(frame: CGPoint(x: star.point.x * size.width, y: star.point.y * size.height),
                            width: star.radius * 2, height: star.radius * 2)
            dot.cornerRadius = star.radius
            dot.backgroundColor = (colors.isDark ? colors.bright : colors.dim).cgColor
            dot.opacity = Float(star.low + 0.4)
            if animated {
                dot.add(basic("opacity", from: Double(star.low), to: 0.95, seconds: star.seconds, offset: star.delay, reverses: true, eased: true),
                        forKey: "twinkle")
            }
            layers.append(dot)
        }
        for ray in scene.rays {
            let height = ray.height * size.height
            let tint = tints[ray.tint % tints.count]
            let bar = CAGradientLayer()
            bar.bounds = CGRect(x: 0, y: 0, width: ray.width, height: height)
            bar.position = CGPoint(x: ray.x * size.width, y: size.height * 0.58 + height / 2)
            // Bright a little above the foot and clear at both ends: a ray has no hard edge.
            bar.colors = [tint.withAlphaComponent(0).cgColor, tint.withAlphaComponent(ray.opacity * strength).cgColor,
                          tint.withAlphaComponent(0).cgColor]
            bar.locations = [0, 0.16, 1]
            bar.startPoint = CGPoint(x: 0.5, y: 0)
            bar.endPoint = CGPoint(x: 0.5, y: 1)
            bar.opacity = 0.7
            if animated {
                bar.add(basic("opacity", from: 0.15, to: 1, seconds: ray.seconds, offset: ray.delay, reverses: true, eased: true), forKey: "shimmer")
                bar.add(basic("position.x", from: Double(bar.position.x - 14), to: Double(bar.position.x + 14),
                              seconds: ray.seconds * 3, offset: ray.delay, reverses: true, eased: true), forKey: "sway")
            }
            layers.append(bar)
        }
        for blob in scene.blobs {
            let tint = tints[blob.tint % tints.count]
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.bounds = CGRect(x: 0, y: 0, width: blob.size.width * size.width, height: blob.size.height * size.height)
            glow.position = CGPoint(x: blob.center.x * size.width, y: blob.center.y * size.height)
            glow.colors = [tint.withAlphaComponent(blob.opacity * strength).cgColor,
                           tint.withAlphaComponent(blob.opacity * strength * 0.4).cgColor,
                           tint.withAlphaComponent(0).cgColor]
            glow.locations = [0, 0.5, 1]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.transform = CATransform3DMakeRotation(blob.rotation, 0, 0, 1)
            if animated {
                glow.add(basic("position.x", from: Double(glow.position.x), to: Double(glow.position.x + blob.drift.dx * size.width),
                               seconds: blob.seconds, offset: blob.delay, reverses: true, eased: true), forKey: "drift")
                glow.add(basic("position.y", from: Double(glow.position.y), to: Double(glow.position.y + blob.drift.dy * size.height),
                               seconds: blob.seconds * 1.3, offset: blob.delay, reverses: true, eased: true), forKey: "lift")
                glow.add(basic("transform.scale", from: 1, to: Double(1 + blob.breath), seconds: blob.seconds * 0.8,
                               offset: blob.delay, reverses: true, eased: true), forKey: "breath")
                glow.add(basic("opacity", from: 1, to: 0.55, seconds: blob.seconds * 1.1, offset: blob.delay, reverses: true, eased: true),
                         forKey: "fade")
            }
            layers.append(glow)
        }
        return layers
    }

    // MARK: - Bug swarm

    /// SF Symbols draw a bug seen from above with its head up; the path animation turns a layer so that its x axis points the way it
    /// goes, so the picture is turned a quarter turn clockwise.
    static func bugImage(kind: BugScene.Kind, length: CGFloat, color: NSColor, scale: CGFloat) -> CGImage? {
        let name = kind == .ant ? "ant.fill" : "ladybug.fill"
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: length, weight: .semibold)) else { return nil }
        let side = length * 1.3
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -.pi / 2)
            context.translateBy(x: -rect.midX, y: -rect.midY)
            let target = NSRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                                width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: target)
            color.set()
            target.fill(using: .sourceAtop)
            return true
        }
        var proposed = CGRect(x: 0, y: 0, width: side * scale, height: side * scale)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    private func bugs() -> [CALayer] {
        let scene = BugScene.make(size: size, seed: seed, intensity: detail)
        let tints = [colors.green, colors.cyan, colors.red]
        var layers: [CALayer] = []
        for colony in scene.colonies {
            let color = tints[colony.tint % tints.count].withAlphaComponent(0.85 * (colors.isDark ? 1 : 0.9))
            let path = CGMutablePath()
            path.move(to: colony.points[0])
            for segment in colony.curve { path.addCurve(to: segment.end, control1: segment.control1, control2: segment.control2) }
            for bug in colony.bugs {
                let side = bug.length * 1.3
                let holder = layer(frame: .zero, width: side, height: side)
                let body = layer(frame: CGPoint(x: side / 2, y: side / 2), width: side, height: side)
                body.contents = Self.bugImage(kind: bug.kind, length: bug.length, color: color, scale: scale)
                holder.addSublayer(body)
                let start = colony.startFraction(of: bug)
                if animated {
                    let walk = CAKeyframeAnimation(keyPath: "position")
                    walk.path = path
                    walk.calculationMode = .paced
                    walk.rotationMode = .rotateAuto
                    walk.duration = colony.seconds
                    walk.timeOffset = start * colony.seconds
                    walk.repeatCount = .infinity
                    walk.isRemovedOnCompletion = false
                    holder.add(walk, forKey: "walk")
                    // A little sway, as legs make a body do.
                    body.add(basic("transform.rotation.z", from: -0.14, to: 0.14, seconds: bug.kind == .ant ? 0.24 : 0.4,
                                   offset: start * 3, reverses: true, eased: true), forKey: "sway")
                } else {
                    let place = colony.sample(start)
                    holder.position = place.point
                    holder.transform = CATransform3DMakeRotation(place.heading, 0, 0, 1)
                }
                layers.append(holder)
            }
        }
        return layers
    }

    // MARK: - Network

    private func network() -> [CALayer] {
        let scene = NetworkScene.make(size: size, seed: seed)
        guard !scene.nodes.isEmpty else { return [] }
        let tints = [colors.green, colors.cyan, colors.purple]
        let strength = colors.strength
        var layers: [CALayer] = []

        let lines = CGMutablePath()
        for edge in scene.edges {
            lines.move(to: scene.nodes[edge.a].point)
            lines.addLine(to: scene.nodes[edge.b].point)
        }
        let linesLayer = CAShapeLayer()
        linesLayer.frame = CGRect(origin: .zero, size: size)
        linesLayer.path = lines
        linesLayer.strokeColor = colors.green.withAlphaComponent(0.26 * strength).cgColor
        linesLayer.fillColor = nil
        linesLayer.lineWidth = 1
        layers.append(linesLayer)

        let dots = CGMutablePath()
        for node in scene.nodes where !node.breathes {
            dots.addEllipse(in: CGRect(x: node.point.x - node.radius, y: node.point.y - node.radius, width: node.radius * 2, height: node.radius * 2))
        }
        let dotsLayer = CAShapeLayer()
        dotsLayer.frame = CGRect(origin: .zero, size: size)
        dotsLayer.path = dots
        dotsLayer.fillColor = colors.green.withAlphaComponent(0.6 * strength).cgColor
        layers.append(dotsLayer)

        for node in scene.nodes where node.breathes {
            let halo = CAGradientLayer()
            halo.type = .radial
            let side = node.radius * 9
            halo.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            halo.position = node.point
            halo.colors = [colors.cyan.withAlphaComponent(0.9 * strength).cgColor,
                           colors.cyan.withAlphaComponent(0.25 * strength).cgColor,
                           colors.cyan.withAlphaComponent(0).cgColor]
            halo.locations = [0, 0.25, 1]
            halo.startPoint = CGPoint(x: 0.5, y: 0.5)
            halo.endPoint = CGPoint(x: 1, y: 1)
            if animated {
                halo.add(basic("opacity", from: 0.25, to: 1, seconds: node.seconds, offset: node.delay, reverses: true, eased: true), forKey: "breath")
            }
            layers.append(halo)
        }

        for pulse in scene.pulses {
            let edge = scene.edges[pulse.edge]
            let from = scene.nodes[edge.a].point, to = scene.nodes[edge.b].point
            let tint = tints[pulse.tint % tints.count]
            let spark = CAGradientLayer()
            spark.type = .radial
            spark.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
            spark.colors = [colors.bright.withAlphaComponent(strength).cgColor,
                            tint.withAlphaComponent(0.7 * strength).cgColor,
                            tint.withAlphaComponent(0).cgColor]
            spark.locations = [0, 0.3, 1]
            spark.startPoint = CGPoint(x: 0.5, y: 0.5)
            spark.endPoint = CGPoint(x: 1, y: 1)
            if animated {
                let total = pulse.travel + pulse.idle
                let run = pulse.travel / total
                spark.position = from
                let move = CAKeyframeAnimation(keyPath: "position")
                move.values = [NSValue(point: from), NSValue(point: to), NSValue(point: to)]
                move.keyTimes = [0, NSNumber(value: run), 1]
                move.duration = total
                move.timeOffset = pulse.delay
                move.repeatCount = .infinity
                move.isRemovedOnCompletion = false
                spark.add(move, forKey: "run")
                let glow = CAKeyframeAnimation(keyPath: "opacity")
                glow.values = [0, 1, 1, 0, 0]
                glow.keyTimes = [0, NSNumber(value: run * 0.12), NSNumber(value: run * 0.88), NSNumber(value: run), 1]
                glow.duration = total
                glow.timeOffset = pulse.delay
                glow.repeatCount = .infinity
                glow.isRemovedOnCompletion = false
                spark.add(glow, forKey: "glow")
                spark.opacity = 0
            } else {
                spark.position = CGPoint(x: from.x + (to.x - from.x) * pulse.stillFraction, y: from.y + (to.y - from.y) * pulse.stillFraction)
            }
            layers.append(spark)
        }
        return layers
    }
}
