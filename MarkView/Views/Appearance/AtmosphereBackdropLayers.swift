import AppKit
import QuartzCore

/// Deep Sea and Warp: two scenes of depth and speed. Motion stays in the render server (Core Animation) and uses no display link or
/// SwiftUI frame timer. Every layer count is bounded, `detail` (1...4) only adds a few bubbles, jellyfish or streaks, and a scene built
/// with `animated` false has the same layers standing where the animation starts them.
extension BackdropBuilder {
    // MARK: - Deep Sea

    /// Under the surface: a glow of light from above with slanted shafts, waves along the top edge, bubbles that rise and a few
    /// jellyfish that pulse and drift. Calm, in the cyan, blue and purple of the theme.
    func deepSea() -> [CALayer] {
        var random = BackdropRandom(seed: seed)
        var layers: [CALayer] = [seaWater()]
        layers += seaShafts(&random)
        layers += seaSurface(&random)
        layers += seaBubbles(&random)
        layers += seaJellyfish(&random)
        return layers
    }

    /// Light from above fading into the deep: the whole window, so the other layers have something to float in.
    private func seaWater() -> CALayer {
        let water = CAGradientLayer()
        water.bounds = CGRect(origin: .zero, size: size)
        water.position = CGPoint(x: size.width / 2, y: size.height / 2)
        water.colors = [colors.cyan.withAlphaComponent(0.2 * colors.strength).cgColor,
                        colors.blue.withAlphaComponent(0.08 * colors.strength).cgColor,
                        NSColor.clear.cgColor,
                        colors.purple.withAlphaComponent(0.08 * colors.strength).cgColor]
        water.locations = [0, 0.32, 0.66, 1]
        water.startPoint = CGPoint(x: 0.5, y: 1)
        water.endPoint = CGPoint(x: 0.5, y: 0)
        return water
    }

    /// A shaft of light as an image, drawn once: soft on both sides, strongest at the top and gone towards the bottom.
    private func seaShaftImage(tint: NSColor) -> CGImage? {
        let width = 48, height = 192
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let memory = context.data else { return nil }
        let rgb = tint.usingColorSpace(.sRGB) ?? .white
        let bytes = memory.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        for row in 0..<height {
            let fade = pow(1 - Double(row) / Double(height), 1.8)
            for column in 0..<width {
                let across = abs(Double(column) / Double(width - 1) * 2 - 1)
                let edge = pow(max(0, 1 - across), 1.5)
                let alpha = edge * fade * 0.95
                let offset = row * context.bytesPerRow + column * 4
                bytes[offset] = UInt8(Double(rgb.redComponent) * alpha * 255)
                bytes[offset + 1] = UInt8(Double(rgb.greenComponent) * alpha * 255)
                bytes[offset + 2] = UInt8(Double(rgb.blueComponent) * alpha * 255)
                bytes[offset + 3] = UInt8(alpha * 255)
            }
        }
        return context.makeImage()
    }

    private func seaShafts(_ random: inout BackdropRandom) -> [CALayer] {
        let images = [colors.cyan, colors.blue].map { seaShaftImage(tint: $0) }
        let count = 4 + detail
        var layers: [CALayer] = []
        for index in 0..<count {
            let x = (CGFloat(index) + random.range(0.1, 0.9)) / CGFloat(count) * size.width * 1.15 - size.width * 0.05
            let width = min(190, max(56, size.width * random.range(0.05, 0.12)))
            let ray = layer(frame: CGPoint(x: x, y: size.height + 8), width: width, height: size.height * random.range(0.7, 1.0))
            ray.anchorPoint = CGPoint(x: 0.5, y: 1)
            ray.contents = images[index % images.count]
            let angle = -0.2 + random.range(-0.1, 0.1)
            ray.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            let level = Double(colors.strength * random.range(0.6, 1)) * (colors.isDark ? 0.9 : 0.75)
            ray.opacity = Float(level)
            let swaySeconds = Double(random.range(14, 24)), swayOffset = Double(random.range(0, 20))
            let breathSeconds = Double(random.range(6, 11)), breathOffset = Double(random.range(0, 10))
            if animated {
                ray.add(basic("transform.rotation.z", from: Double(angle - 0.05), to: Double(angle + 0.05), seconds: swaySeconds, offset: swayOffset,
                              reverses: true, eased: true), forKey: "sway")
                ray.add(basic("opacity", from: level * 0.45, to: level, seconds: breathSeconds, offset: breathOffset, reverses: true, eased: true), forKey: "shimmer")
            }
            layers.append(ray)
        }
        return layers
    }

    /// A wave line across the whole width, as quadratic pieces; `flip` turns every crest into a trough, so a path and its flipped twin
    /// have the same structure and Core Animation can morph one into the other.
    private func seaWavePath(baseline: CGFloat, amplitude: CGFloat, half: CGFloat, flip: CGFloat) -> CGPath {
        let start = -half
        let count = Int(ceil((size.width + 2 * half) / half))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start, y: baseline))
        for index in 0..<count {
            let sign: CGFloat = (index % 2 == 0 ? 1 : -1) * flip
            let x = start + CGFloat(index) * half
            path.addQuadCurve(to: CGPoint(x: x + half, y: baseline), control: CGPoint(x: x + half / 2, y: baseline + sign * amplitude * 2))
        }
        let end = start + CGFloat(count) * half
        path.addLine(to: CGPoint(x: end, y: size.height + 40))
        path.addLine(to: CGPoint(x: start, y: size.height + 40))
        path.closeSubpath()
        return path
    }

    /// The surface seen from below: bands of light above three wave lines that swell and settle.
    private func seaSurface(_ random: inout BackdropRandom) -> [CALayer] {
        let depth = min(90, max(36, size.height * 0.07))
        var layers: [CALayer] = []
        for index in 0..<3 {
            let baseline = size.height - depth + CGFloat(index) * depth * 0.22
            let amplitude = depth * (0.2 - CGFloat(index) * 0.04)
            let half = max(70, size.width / 11) * (1 + CGFloat(index) * 0.18)
            let from = seaWavePath(baseline: baseline, amplitude: amplitude, half: half, flip: 1)
            let tint = index == 1 ? colors.blue : colors.cyan
            let band = shape(from, stroke: (index == 2 ? colors.bright : colors.cyan).withAlphaComponent((0.3 - CGFloat(index) * 0.07) * colors.strength),
                             fill: tint.withAlphaComponent((0.09 - CGFloat(index) * 0.02) * colors.strength), width: 1.2)
            if animated {
                let morph = CABasicAnimation(keyPath: "path")
                morph.fromValue = from
                morph.toValue = seaWavePath(baseline: baseline, amplitude: amplitude, half: half, flip: -1)
                morph.duration = Double(random.range(5, 9))
                morph.timeOffset = Double(random.range(0, 8))
                morph.autoreverses = true
                morph.repeatCount = .infinity
                morph.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                morph.isRemovedOnCompletion = false
                band.add(morph, forKey: "swell")
            }
            layers.append(band)
        }
        return layers
    }

    private func seaBubbles(_ random: inout BackdropRandom) -> [CALayer] {
        var layers: [CALayer] = []
        for _ in 0..<(18 + detail * 7) {
            let diameter = random.range(5, 17)
            let x = random.range(0.03, 0.97) * size.width
            let speed = random.range(22, 46) * sqrt(diameter / 10)
            let start = -diameter, end = size.height + diameter
            let seconds = Double((end - start) / speed)
            let phase = Double(random.unit())
            let bubble = shape(CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: diameter - 1, height: diameter - 1), transform: nil),
                               stroke: (colors.isDark ? colors.bright : colors.blue).withAlphaComponent(0.4 * colors.strength),
                               fill: colors.cyan.withAlphaComponent(0.07 * colors.strength), width: 1)
            bubble.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            bubble.position = CGPoint(x: x, y: start + (end - start) * CGFloat(phase))
            let swayAmount = Double(random.range(5, 14)), swaySeconds = Double(random.range(2.5, 5.5)), swayOffset = Double(random.range(0, 6))
            if animated {
                bubble.add(basic("position.y", from: Double(start), to: Double(end), seconds: seconds, offset: phase * seconds), forKey: "rise")
                bubble.add(basic("position.x", from: Double(x) - swayAmount, to: Double(x) + swayAmount, seconds: swaySeconds, offset: swayOffset,
                                 reverses: true, eased: true), forKey: "wobble")
            }
            layers.append(bubble)
        }
        return layers
    }

    /// Tentacles as a few wavy strands; `flip` mirrors every sideways bend, so the two paths morph into each other.
    private func seaTentaclePath(width: CGFloat, length: CGFloat, flip: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let lengths: [CGFloat] = [0.85, 1, 0.7, 1, 0.8]
        for strand in 0..<lengths.count {
            let x = width * (0.14 + 0.18 * CGFloat(strand))
            let bend = width * 0.1 * flip * (strand % 2 == 0 ? 1 : -1)
            let bottom = length * (1 - lengths[strand])
            path.move(to: CGPoint(x: x, y: length))
            path.addCurve(to: CGPoint(x: x + bend, y: bottom + (length - bottom) * 0.5),
                          control1: CGPoint(x: x + bend * 1.6, y: length * 0.9), control2: CGPoint(x: x - bend * 1.2, y: bottom + (length - bottom) * 0.62))
            path.addCurve(to: CGPoint(x: x - bend * 0.6, y: bottom),
                          control1: CGPoint(x: x + bend * 1.3, y: bottom + (length - bottom) * 0.38), control2: CGPoint(x: x - bend * 1.8, y: bottom + (length - bottom) * 0.18))
        }
        return path
    }

    private func seaJellyfish(_ random: inout BackdropRandom) -> [CALayer] {
        let count = min(5, 2 + detail)
        let jellyTints = [colors.cyan, colors.purple, colors.blue, colors.cyan, colors.purple]
        var layers: [CALayer] = []
        for index in 0..<count {
            let tint = jellyTints[index]
            let width = min(max(min(size.width, size.height) * 0.11, 48), 112) * random.range(0.8, 1.25)
            let bellHeight = width * 0.72
            let tentacleLength = width * random.range(1.1, 1.6)
            let slot = (CGFloat(index) + 0.5) / CGFloat(count)
            let center = CGPoint(x: (slot + random.range(-0.05, 0.05)) * size.width, y: random.range(0.25, 0.72) * size.height)
            let jelly = layer(frame: center, width: width, height: bellHeight + tentacleLength)

            let tentacles = shape(seaTentaclePath(width: width, length: tentacleLength, flip: 1), stroke: tint.withAlphaComponent(0.42 * colors.strength), width: 1.2)
            if animated {
                let sway = CABasicAnimation(keyPath: "path")
                sway.fromValue = seaTentaclePath(width: width, length: tentacleLength, flip: 1)
                sway.toValue = seaTentaclePath(width: width, length: tentacleLength, flip: -1)
                sway.duration = Double(random.range(2.2, 3.6))
                sway.timeOffset = Double(random.range(0, 4))
                sway.autoreverses = true
                sway.repeatCount = .infinity
                sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                sway.isRemovedOnCompletion = false
                tentacles.add(sway, forKey: "trail")
            }
            jelly.addSublayer(tentacles)

            let dome = CGMutablePath()
            dome.move(to: .zero)
            dome.addCurve(to: CGPoint(x: width, y: 0), control1: CGPoint(x: 0, y: bellHeight * 1.34), control2: CGPoint(x: width, y: bellHeight * 1.34))
            dome.addQuadCurve(to: .zero, control: CGPoint(x: width / 2, y: bellHeight * 0.2))
            let bell = shape(dome, stroke: tint.withAlphaComponent(0.62 * colors.strength), fill: tint.withAlphaComponent(0.13 * colors.strength), width: 1.3)
            bell.bounds = CGRect(x: 0, y: 0, width: width, height: bellHeight)
            bell.anchorPoint = CGPoint(x: 0.5, y: 0)
            bell.position = CGPoint(x: width / 2, y: tentacleLength)
            let core = glow(at: CGPoint(x: width / 2, y: bellHeight * 0.42), radius: width * 0.62, tint: tint)
            core.opacity = 0.5
            bell.addSublayer(core)
            let pulseSeconds = Double(random.range(1.9, 2.7)), pulseOffset = Double(random.range(0, 3))
            if animated {
                bell.add(basic("transform.scale.y", from: 0.84, to: 1, seconds: pulseSeconds, offset: pulseOffset, reverses: true, eased: true), forKey: "pulse-height")
                bell.add(basic("transform.scale.x", from: 1.07, to: 0.97, seconds: pulseSeconds, offset: pulseOffset, reverses: true, eased: true), forKey: "pulse-width")
            }
            jelly.addSublayer(bell)

            let lift = Double(random.range(18, 34)), liftSeconds = Double(random.range(6, 10)), liftOffset = Double(random.range(0, 10))
            let side = Double(random.range(10, 22)), sideSeconds = Double(random.range(9, 14)), sideOffset = Double(random.range(0, 14))
            let tilt = Double(random.range(0.04, 0.09)), tiltSeconds = Double(random.range(7, 12)), tiltOffset = Double(random.range(0, 12))
            if animated {
                jelly.add(basic("position.y", from: Double(center.y) - lift, to: Double(center.y) + lift, seconds: liftSeconds, offset: liftOffset, reverses: true, eased: true), forKey: "lift")
                jelly.add(basic("position.x", from: Double(center.x) - side, to: Double(center.x) + side, seconds: sideSeconds, offset: sideOffset, reverses: true, eased: true), forKey: "sidestep")
                jelly.add(basic("transform.rotation.z", from: -tilt, to: tilt, seconds: tiltSeconds, offset: tiltOffset, reverses: true, eased: true), forKey: "tilt")
            }
            layers.append(jelly)
        }
        return layers
    }

    // MARK: - Warp

    /// Hyperspace: faint stars behind, and streaks that leave a vanishing point a little off the centre, speed up and fade out at the
    /// edges. Slow on purpose: nothing flashes and nothing changes brightness quickly.
    func warp() -> [CALayer] {
        var random = BackdropRandom(seed: seed)
        var layers: [CALayer] = []
        let starTints = colors.isDark ? [colors.bright, colors.cyan, colors.purple] : [colors.blue, colors.purple, colors.cyan]
        for index in 0..<(26 + detail * 8) {
            let point = CGPoint(x: random.unit() * size.width, y: random.unit() * size.height)
            let star = glow(at: point, radius: random.range(0.9, 2), tint: starTints[index % starTints.count])
            star.opacity = Float(random.range(0.45, 0.95))
            let twinkle = Double(random.range(2, 5)), twinkleOffset = Double(random.range(0, 5))
            let drift = Double(random.range(6, 11)), driftSeconds = Double(random.range(9, 16)), driftOffset = Double(random.range(0, 16))
            if animated {
                star.add(basic("opacity", from: 0.25, to: 1, seconds: twinkle, offset: twinkleOffset, reverses: true, eased: true), forKey: "twinkle")
                star.add(basic("position.x", from: Double(point.x) - drift, to: Double(point.x) + drift, seconds: driftSeconds, offset: driftOffset, reverses: true, eased: true), forKey: "drift")
            }
            layers.append(star)
        }
        layers.append(warpField(&random))
        return layers
    }

    /// What a cubic Bézier timing curve through (0, 0), (x1, y1), (x2, y2) and (1, 1) does to a fraction of the time (as CAMediaTimingFunction).
    private static func warpProgress(_ time: Double, _ curve: (Double, Double, Double, Double)) -> Double {
        func bezier(_ t: Double, _ first: Double, _ second: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * first + 3 * (1 - t) * t * t * second + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if bezier(middle, curve.0, curve.2) < time { low = middle } else { high = middle }
        }
        return bezier((low + high) / 2, curve.1, curve.3)
    }

    /// The glow at the vanishing point and every streak, in one layer that drifts slowly, so the vanishing point wanders a little.
    private func warpField(_ random: inout BackdropRandom) -> CALayer {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let field = layer(frame: center, width: size.width, height: size.height)
        let vanishing = CGPoint(x: size.width * 0.46, y: size.height * 0.56)
        let glowRadius = min(size.width, size.height) * 0.2
        // A glow with an eased edge: the plain two-colour radial gradient shows a faint ring where it ends.
        let haze = CAGradientLayer()
        haze.type = .radial
        haze.bounds = CGRect(x: 0, y: 0, width: glowRadius * 2, height: glowRadius * 2)
        haze.position = vanishing
        haze.colors = [0.8, 0.32, 0.09, 0.02, 0].map { colors.blue.withAlphaComponent($0 * colors.strength).cgColor }
        haze.locations = [0, 0.35, 0.65, 0.85, 1]
        haze.startPoint = CGPoint(x: 0.5, y: 0.5)
        haze.endPoint = CGPoint(x: 1, y: 1)
        haze.opacity = 0.45
        let core = glow(at: vanishing, radius: glowRadius * 0.4, tint: colors.isDark ? colors.bright : colors.purple)
        core.opacity = 0.3
        if animated {
            haze.add(basic("transform.scale", from: 0.9, to: 1.15, seconds: 9, reverses: true, eased: true), forKey: "haze")
            core.add(basic("opacity", from: 0.18, to: 0.38, seconds: 7, offset: 2, reverses: true, eased: true), forKey: "core")
        }
        field.addSublayer(haze)
        field.addSublayer(core)

        let farthest = hypot(max(vanishing.x, size.width - vanishing.x), max(vanishing.y, size.height - vanishing.y))
        let startRadius = min(size.width, size.height) * 0.03
        let streakTints = colors.isDark ? [colors.bright, colors.bright, colors.cyan, colors.blue, colors.purple] : [colors.blue, colors.purple, colors.cyan, colors.blue, colors.bright]
        // A streak speeds up as it comes closer: the distance and the length follow this curve of the time. Every animation of a streak
        // uses it as its timing function, so the key times of the fade are fractions of the distance too, and the still picture can stand
        // exactly where the animation would be.
        let curve: (Double, Double, Double, Double) = (0.3, 0.05, 0.75, 0.45)
        let accelerate = CAMediaTimingFunction(controlPoints: Float(curve.0), Float(curve.1), Float(curve.2), Float(curve.3))
        for index in 0..<(88 + detail * 14) {
            let angle = CGFloat(index) * 2.399_963 + random.range(-0.06, 0.06)
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let maxLength = random.range(70, 190), thickness = random.range(1, 2.1)
            let endRadius = farthest + maxLength + 20
            let seconds = Double(random.range(7, 14))
            // Another irrational step than the angle's (the golden angle), or the streaks of one direction would all be at one distance.
            let phase = (Double(index) * 0.754_878 + Double(random.range(0, 0.1))).truncatingRemainder(dividingBy: 1)
            let progress = CGFloat(Self.warpProgress(phase, curve))
            let peak = random.range(0.3, 0.7) * colors.strength
            let tint = streakTints[random.int(streakTints.count)]

            let streak = CAGradientLayer()
            streak.anchorPoint = CGPoint(x: 0, y: 0.5)
            streak.bounds = CGRect(x: 0, y: 0, width: 6 + (maxLength - 6) * progress, height: thickness)
            streak.position = CGPoint(x: vanishing.x + direction.x * (startRadius + (endRadius - startRadius) * progress),
                                      y: vanishing.y + direction.y * (startRadius + (endRadius - startRadius) * progress))
            streak.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            streak.colors = [tint.withAlphaComponent(0).cgColor, tint.cgColor]
            streak.startPoint = CGPoint(x: 0, y: 0.5)
            streak.endPoint = CGPoint(x: 1, y: 0.5)
            streak.contentsScale = scale
            // Fades in close to the vanishing point, holds across the window, fades out at the far edge: 0, 1, 1, 0 at these fractions of
            // the distance.
            let times: [Double] = [0, 0.1, 0.82, 1]
            let levels: [Double] = [0, 1, 1, 0]
            var level = 0.0
            for segment in 1..<times.count where Double(progress) <= times[segment] {
                let span = times[segment] - times[segment - 1]
                level = levels[segment - 1] + (levels[segment] - levels[segment - 1]) * (Double(progress) - times[segment - 1]) / span
                break
            }
            streak.opacity = Float(Double(peak) * level)
            if animated {
                func travel(_ keyPath: String, from: Double, to: Double) -> CABasicAnimation {
                    let animation = basic(keyPath, from: from, to: to, seconds: seconds, offset: phase * seconds)
                    animation.timingFunction = accelerate
                    return animation
                }
                streak.add(travel("position.x", from: Double(vanishing.x + direction.x * startRadius), to: Double(vanishing.x + direction.x * endRadius)), forKey: "fly-x")
                streak.add(travel("position.y", from: Double(vanishing.y + direction.y * startRadius), to: Double(vanishing.y + direction.y * endRadius)), forKey: "fly-y")
                streak.add(travel("bounds.size.width", from: 6, to: Double(maxLength)), forKey: "stretch")
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = levels.map { Float($0 * Double(peak)) }
                fade.keyTimes = times.map { NSNumber(value: $0) }
                fade.duration = seconds
                fade.timeOffset = phase * seconds
                fade.timingFunction = accelerate
                fade.repeatCount = .infinity
                fade.isRemovedOnCompletion = false
                streak.add(fade, forKey: "fade")
            }
            field.addSublayer(streak)
        }
        if animated {
            let reach = Double(min(size.width, size.height)) * 0.035
            field.add(basic("position.x", from: Double(center.x) - reach, to: Double(center.x) + reach, seconds: 23, offset: 5, reverses: true, eased: true), forKey: "wander-x")
            field.add(basic("position.y", from: Double(center.y) - reach * 0.7, to: Double(center.y) + reach * 0.7, seconds: 31, offset: 11, reverses: true, eased: true), forKey: "wander-y")
        }
        return field
    }
}
