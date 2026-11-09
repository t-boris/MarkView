import Foundation
import CoreGraphics

/// The animated picture behind the welcome screen (feature welcome-screen-with-action-tiles-and-a-falling, REQ-002).
/// Only the choice and the scenes live here, as plain values: `WelcomeBackdropView` turns a scene into Core Animation layers.
/// All scene coordinates follow the layer tree: the origin is the bottom left corner and y grows upwards.
enum WelcomeBackdrop: String, CaseIterable, Identifiable {
    case matrix, aurora, bugs, network, shuffle, off

    var id: String { rawValue }

    /// One UserDefaults value for every window (DEC-002).
    static let storageKey = "welcomeBackdrop"
    static let defaultChoice = WelcomeBackdrop.matrix
    /// What Shuffle picks from.
    static let animated: [WelcomeBackdrop] = [.matrix, .aurora, .bugs, .network]

    var title: String {
        switch self {
        case .matrix: return "Matrix Rain"
        case .aurora: return "Aurora"
        case .bugs: return "Bug Swarm"
        case .network: return "Network"
        case .shuffle: return "Shuffle"
        case .off: return "Off"
        }
    }

    var symbol: String {
        switch self {
        case .matrix: return "chevron.left.forwardslash.chevron.right"
        case .aurora: return "sparkles"
        case .bugs: return "ladybug"
        case .network: return "point.3.connected.trianglepath.dotted"
        case .shuffle: return "shuffle"
        case .off: return "circle.slash"
        }
    }

    /// A stored value is used only when it names a backdrop; anything else (missing, renamed) is the default.
    static func stored(_ raw: String?) -> WelcomeBackdrop {
        raw.flatMap(WelcomeBackdrop.init(rawValue:)) ?? defaultChoice
    }

    /// The scene to draw. Shuffle becomes one of the animated ones, chosen by `pick`: the screen draws that number once each time it
    /// appears, so the scene does not change while it is shown.
    func scene(pick: Int) -> WelcomeBackdrop {
        guard self == .shuffle else { return self }
        let count = Self.animated.count
        return Self.animated[((pick % count) + count) % count]
    }
}

/// A small seeded generator (SplitMix64): one seed gives one scene, so a rebuild at another window size keeps the look and the checks
/// are reproducible.
struct BackdropRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }

    mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * unit() }

    /// 0 ..< count (count must be positive)
    mutating func int(_ count: Int) -> Int { Int(next() % UInt64(max(1, count))) }

    mutating func chance(_ probability: CGFloat) -> Bool { unit() < probability }
}

// MARK: - Matrix rain

/// Columns of symbols that fall at different speeds and change while they fall.
struct MatrixScene: Equatable {
    /// Half-width katakana, digits and the punctuation of Markdown and code.
    static let alphabet: [Character] = Array("ｦｱｳｴｵｶｷｹｺｻｼｽｾﾀﾂﾃﾅﾆﾇﾈﾊﾋﾎﾏﾐﾑﾒﾓﾔﾕﾗﾘﾜ0123456789=*+-<>|:.#[]{}()/~_")
    /// The strips come in these lengths (in symbols); a column keeps one length, so its image keeps its size.
    static let lengths = [9, 13, 17, 21, 26]
    /// How many versions of the symbols a strip has: each differs from the one before in a few symbols, so the column seems to flicker
    /// instead of being rewritten.
    static let variantsPerLength = 6
    static let maxColumns = 220

    struct Column: Equatable {
        /// Left edge.
        var x: CGFloat
        var lengthIndex: Int
        /// Points per second.
        var speed: CGFloat
        /// 0 ..< 1: how far along its fall the strip is when the screen appears.
        var phase: CGFloat
        /// The order the versions are shown in, one after the other.
        var variantOrder: [Int]
        /// How long one version stays.
        var variantSeconds: Double
    }

    let size: CGSize
    let cell: CGSize
    let columns: [Column]
    /// strips[lengthIndex][variant] = the symbols, tail first and head last.
    let strips: [[[Character]]]

    func stripHeight(_ column: Column) -> CGFloat { CGFloat(Self.lengths[column.lengthIndex]) * cell.height }

    /// Centre of the strip when it enters (just above the top edge) and when it has left (just below the bottom edge).
    func startCenterY(_ column: Column) -> CGFloat { size.height + stripHeight(column) / 2 }
    func endCenterY(_ column: Column) -> CGFloat { -stripHeight(column) / 2 }

    /// Seconds for one fall.
    func fallSeconds(_ column: Column) -> Double {
        Double((startCenterY(column) - endCenterY(column)) / column.speed)
    }

    /// Where the centre of the strip is at the start: the still picture, and the first frame of the animation.
    func initialCenterY(_ column: Column) -> CGFloat {
        startCenterY(column) - column.phase * (startCenterY(column) - endCenterY(column))
    }

    static func make(size: CGSize, cell: CGSize, seed: UInt64) -> MatrixScene {
        var random = BackdropRandom(seed: seed)
        var strips: [[[Character]]] = []
        for length in lengths {
            var base = (0..<length).map { _ in alphabet[random.int(alphabet.count)] }
            var variants = [base]
            for _ in 1..<variantsPerLength {
                // The head always changes, and a quarter of the others.
                base[length - 1] = alphabet[random.int(alphabet.count)]
                for _ in 0..<max(2, length / 4) { base[random.int(length - 1)] = alphabet[random.int(alphabet.count)] }
                variants.append(base)
            }
            strips.append(variants)
        }
        guard size.width >= 40, size.height >= 40, cell.width > 0, cell.height > 0 else {
            return MatrixScene(size: size, cell: cell, columns: [], strips: strips)
        }
        let count = Int(size.width / cell.width)
        let margin = (size.width - CGFloat(count) * cell.width) / 2
        var columns: [Column] = []
        for index in 0..<count {
            // Most positions carry one stream; some carry a second one, so the streams overlap a little.
            for chanceOfStream: CGFloat in [0.62, 0.22] {
                guard columns.count < maxColumns else { break }
                guard random.chance(chanceOfStream) else { continue }
                let first = random.int(variantsPerLength)
                columns.append(Column(
                    x: margin + CGFloat(index) * cell.width,
                    lengthIndex: random.int(lengths.count),
                    speed: random.range(70, 190),
                    phase: random.unit(),
                    variantOrder: (0..<variantsPerLength).map { (first + $0) % variantsPerLength },
                    variantSeconds: Double(random.range(0.5, 1.4))))
            }
        }
        return MatrixScene(size: size, cell: cell, columns: columns, strips: strips)
    }
}

// MARK: - Aurora

/// Slowly drifting bands of light, rays and a few stars. Coordinates are fractions of the window, so one scene fits every size.
struct AuroraScene: Equatable {
    /// The light colours a scene uses (the view maps them onto the theme: green, cyan, purple, blue).
    static let tintCount = 4

    struct Blob: Equatable {
        var center: CGPoint
        /// Fractions of the width and of the height.
        var size: CGSize
        var rotation: CGFloat
        var tint: Int
        var opacity: CGFloat
        /// How far it drifts, in fractions of the window.
        var drift: CGVector
        var breath: CGFloat
        var seconds: Double
        var delay: Double
    }

    struct Ray: Equatable {
        var x: CGFloat
        /// Points.
        var width: CGFloat
        /// A fraction of the height.
        var height: CGFloat
        var tint: Int
        var opacity: CGFloat
        var seconds: Double
        var delay: Double
    }

    struct Star: Equatable {
        var point: CGPoint
        /// Points.
        var radius: CGFloat
        var low: CGFloat
        var seconds: Double
        var delay: Double
    }

    let blobs: [Blob]
    let rays: [Ray]
    let stars: [Star]

    static func make(seed: UInt64) -> AuroraScene {
        var random = BackdropRandom(seed: seed)
        let blobs = (0..<7).map { index in
            Blob(center: CGPoint(x: random.range(0.08, 0.92), y: random.range(0.5, 0.92)),
                 size: CGSize(width: random.range(0.45, 0.8), height: random.range(0.16, 0.3)),
                 rotation: random.range(-0.35, 0.35),
                 tint: index % tintCount,
                 opacity: random.range(0.32, 0.55),
                 drift: CGVector(dx: random.range(-0.18, 0.18), dy: random.range(-0.05, 0.05)),
                 breath: random.range(0.08, 0.22),
                 seconds: Double(random.range(14, 26)),
                 delay: Double(random.range(0, 10)))
        }
        let rays = (0..<44).map { _ in
            Ray(x: random.unit(),
                width: random.range(1.5, 4),
                height: random.range(0.25, 0.55),
                tint: random.int(tintCount),
                opacity: random.range(0.1, 0.3),
                seconds: Double(random.range(3, 8)),
                delay: Double(random.range(0, 8)))
        }
        let stars = (0..<70).map { _ in
            Star(point: CGPoint(x: random.unit(), y: random.range(0.35, 1)),
                 radius: random.range(0.6, 1.6),
                 low: random.range(0.05, 0.3),
                 seconds: Double(random.range(1.6, 5)),
                 delay: Double(random.range(0, 5)))
        }
        return AuroraScene(blobs: blobs, rays: rays, stars: stars)
    }
}

// MARK: - Bug swarm

/// Ants and ladybugs that crawl along curved paths across the window, facing the way they go; the ants march in lines.
struct BugScene: Equatable {
    enum Kind: Equatable { case ant, ladybug }

    struct Bug: Equatable {
        var kind: Kind
        /// Seconds behind the leader of its colony.
        var lag: Double
        /// Points.
        var length: CGFloat
    }

    struct Segment: Equatable {
        var control1: CGPoint
        var control2: CGPoint
        var end: CGPoint
    }

    struct Colony: Equatable {
        /// The points the path goes through, from outside one edge to outside another.
        var points: [CGPoint]
        var curve: [Segment]
        /// The curve cut into short straight pieces, with the length along it of each point.
        var polyline: [CGPoint]
        var distances: [CGFloat]
        /// Seconds for one crossing.
        var seconds: Double
        /// 0 ..< 1: how far along its path the leader is when the screen appears.
        var phase: Double
        var tint: Int
        var bugs: [Bug]

        var pathLength: CGFloat { distances.last ?? 0 }

        /// Where the path is at `fraction` of its length (wraps around), and which way it points, in radians.
        func sample(_ fraction: Double) -> (point: CGPoint, heading: CGFloat) {
            guard polyline.count >= 2, pathLength > 0 else { return (polyline.first ?? .zero, 0) }
            var wrapped = fraction.truncatingRemainder(dividingBy: 1)
            if wrapped < 0 { wrapped += 1 }
            let target = CGFloat(wrapped) * pathLength
            var index = 1
            while index < distances.count - 1, distances[index] < target { index += 1 }
            let from = polyline[index - 1], to = polyline[index]
            let span = max(distances[index] - distances[index - 1], 0.0001)
            let t = min(1, max(0, (target - distances[index - 1]) / span))
            return (CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t),
                    atan2(to.y - from.y, to.x - from.x))
        }

        /// Fraction of the path a bug is at when the screen appears.
        func startFraction(of bug: Bug) -> Double {
            var fraction = (phase - bug.lag / seconds).truncatingRemainder(dividingBy: 1)
            if fraction < 0 { fraction += 1 }
            return fraction
        }
    }

    let size: CGSize
    let colonies: [Colony]

    static let tintCount = 3

    /// Catmull-Rom through the points, as cubic Bézier pieces.
    static func smooth(_ points: [CGPoint]) -> [Segment] {
        guard points.count >= 2 else { return [] }
        func point(_ index: Int) -> CGPoint { points[min(max(index, 0), points.count - 1)] }
        return (0..<(points.count - 1)).map { i in
            let p0 = point(i - 1), p1 = point(i), p2 = point(i + 1), p3 = point(i + 2)
            return Segment(control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                           control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6),
                           end: p2)
        }
    }

    static func flatten(start: CGPoint, curve: [Segment], steps: Int = 18) -> (points: [CGPoint], distances: [CGFloat]) {
        var points = [start]
        var current = start
        for segment in curve {
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps), u = 1 - t
                let x = u * u * u * current.x + 3 * u * u * t * segment.control1.x + 3 * u * t * t * segment.control2.x + t * t * t * segment.end.x
                let y = u * u * u * current.y + 3 * u * u * t * segment.control1.y + 3 * u * t * t * segment.control2.y + t * t * t * segment.end.y
                points.append(CGPoint(x: x, y: y))
            }
            current = segment.end
        }
        var distances: [CGFloat] = [0]
        for index in 1..<points.count {
            distances.append(distances[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        return (points, distances)
    }

    static func make(size: CGSize, seed: UInt64) -> BugScene {
        guard size.width >= 40, size.height >= 40 else { return BugScene(size: size, colonies: []) }
        var random = BackdropRandom(seed: seed)
        let margin: CGFloat = 36
        func edgePoint(side: Int, along: CGFloat) -> CGPoint {
            switch side {
            case 0: return CGPoint(x: along * size.width, y: size.height + margin)
            case 1: return CGPoint(x: size.width + margin, y: along * size.height)
            case 2: return CGPoint(x: along * size.width, y: -margin)
            default: return CGPoint(x: -margin, y: along * size.height)
            }
        }
        let count = min(9, max(3, Int(size.width * size.height / 140_000)))
        var colonies: [Colony] = []
        for index in 0..<count {
            let startSide = random.int(4)
            let endSide = random.chance(0.7) ? (startSide + 2) % 4 : (startSide + (random.chance(0.5) ? 1 : 3)) % 4
            let start = edgePoint(side: startSide, along: random.range(0.1, 0.9))
            let end = edgePoint(side: endSide, along: random.range(0.1, 0.9))
            let direction = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let length = max(hypot(direction.x, direction.y), 1)
            let normal = CGPoint(x: -direction.y / length, y: direction.x / length)
            let inner = 4 + random.int(3)
            var points = [start]
            for step in 1...inner {
                let t = CGFloat(step) / CGFloat(inner + 1)
                let sway = random.range(-0.22, 0.22) * min(size.width, size.height)
                points.append(CGPoint(x: start.x + direction.x * t + normal.x * sway, y: start.y + direction.y * t + normal.y * sway))
            }
            points.append(end)
            let curve = smooth(points)
            let flat = flatten(start: start, curve: curve)
            let ladybugs = index % 3 == 2
            let speed = random.range(ladybugs ? 26 : 38, ladybugs ? 46 : 72)
            let seconds = Double((flat.distances.last ?? 1) / speed)
            var bugs: [Bug] = []
            if ladybugs {
                bugs = [Bug(kind: .ladybug, lag: 0, length: 28)]
                if random.chance(0.4) { bugs.append(Bug(kind: .ladybug, lag: Double(random.range(1.5, 3)), length: 24)) }
            } else {
                let gap = random.range(30, 40)
                let followers = 2 + random.int(4)
                bugs = (0...followers).map { Bug(kind: .ant, lag: Double(CGFloat($0) * gap / speed), length: 22) }
            }
            colonies.append(Colony(points: points, curve: curve, polyline: flat.points, distances: flat.distances,
                                   seconds: seconds, phase: Double(random.unit()),
                                   tint: ladybugs ? 2 : random.int(2), bugs: bugs))
        }
        return BugScene(size: size, colonies: colonies)
    }
}

// MARK: - Network

/// Nodes joined by lines, with pulses of light that run along the lines.
struct NetworkScene: Equatable {
    struct Node: Equatable {
        var point: CGPoint
        var radius: CGFloat
        /// A node that glows and dims.
        var breathes: Bool
        var seconds: Double
        var delay: Double
    }

    struct Edge: Equatable {
        var a: Int
        var b: Int
    }

    struct Pulse: Equatable {
        var edge: Int
        /// Seconds to cross the line.
        var travel: Double
        /// Seconds of rest before the next run.
        var idle: Double
        var delay: Double
        var tint: Int
        /// Where on the line it stands in the still picture.
        var stillFraction: CGFloat
    }

    static let tintCount = 3

    let size: CGSize
    let nodes: [Node]
    let edges: [Edge]
    let pulses: [Pulse]

    static func make(size: CGSize, seed: UInt64) -> NetworkScene {
        guard size.width >= 40, size.height >= 40 else { return NetworkScene(size: size, nodes: [], edges: [], pulses: []) }
        var random = BackdropRandom(seed: seed)
        // One jittered node per grid cell; the cell grows when the window is so big that there would be too many nodes.
        let spacing = max(120, sqrt(size.width * size.height / 140))
        let columns = max(2, Int(size.width / spacing)), rows = max(2, Int(size.height / spacing))
        let cellWidth = size.width / CGFloat(columns), cellHeight = size.height / CGFloat(rows)
        var nodes: [Node] = []
        for row in 0..<rows {
            for column in 0..<columns {
                nodes.append(Node(
                    point: CGPoint(x: (CGFloat(column) + random.range(0.15, 0.85)) * cellWidth,
                                   y: (CGFloat(row) + random.range(0.15, 0.85)) * cellHeight),
                    radius: random.range(1.8, 3.4),
                    breathes: random.chance(0.3),
                    seconds: Double(random.range(1.8, 4.5)),
                    delay: Double(random.range(0, 4))))
            }
        }
        var edges: [Edge] = []
        var seen = Set<Int>()
        for (index, node) in nodes.enumerated() {
            let near = nodes.indices.filter { $0 != index }.sorted {
                hypot(nodes[$0].point.x - node.point.x, nodes[$0].point.y - node.point.y)
                    < hypot(nodes[$1].point.x - node.point.x, nodes[$1].point.y - node.point.y)
            }
            let links = random.chance(0.3) ? 3 : 2
            for other in near.prefix(links) {
                let low = min(index, other), high = max(index, other)
                if seen.insert(low * nodes.count + high).inserted { edges.append(Edge(a: low, b: high)) }
            }
        }
        var pulses: [Pulse] = []
        for index in edges.indices where random.chance(0.4) {
            pulses.append(Pulse(edge: index,
                                travel: Double(random.range(1.6, 4)),
                                idle: Double(random.range(1, 7)),
                                delay: Double(random.range(0, 6)),
                                tint: random.int(tintCount),
                                stillFraction: random.range(0.2, 0.8)))
        }
        return NetworkScene(size: size, nodes: nodes, edges: edges, pulses: pulses)
    }
}
