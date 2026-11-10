import AppKit
import SwiftUI
import ObjectiveC

// The welcome screen (feature welcome-screen-with-action-tiles-and-a-falling): the scenes of the four backdrops and the list of actions as
// plain values, the layers a scene becomes, and the shipping WelcomeScreen hosted off screen (a borderless window far outside the
// display, never shown). Run through tools/tests/welcome-screen-tests.sh, which compiles the real files.
// With SNAPSHOT_DIR set, every backdrop in a dark and a light theme is saved as a picture, to be looked at.

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message)\(ok || detail.isEmpty ? "" : " — " + detail)")
}

func finite(_ value: CGFloat) -> Bool { value.isFinite }

// MARK: - The choice

func choiceChecks() {
    check(WelcomeBackdrop.stored(nil) == .matrix, "no stored choice: Matrix Rain is the default")
    check(WelcomeBackdrop.stored("bogus") == .matrix, "a stored value that names nothing: the default")
    check(WelcomeBackdrop.stored("aurora") == .aurora, "a stored name is read back")
    check(WelcomeBackdrop.allCases.map(\.rawValue).count == Set(WelcomeBackdrop.allCases.map(\.rawValue)).count, "every backdrop has its own stored name")
    check(Set(WelcomeBackdrop.allCases.map(\.title)).count == WelcomeBackdrop.allCases.count, "every backdrop has its own title")
    let picked = Set((-9...30).map { WelcomeBackdrop.shuffle.scene(pick: $0) })
    check(picked == Set(WelcomeBackdrop.animated), "Shuffle reaches every animated backdrop and nothing else", "\(picked.map(\.rawValue).sorted())")
    check(WelcomeBackdrop.allCases.filter { $0 != .shuffle }.allSatisfy { $0.scene(pick: 3) == $0 }, "a chosen backdrop is drawn as itself")
    check(!WelcomeBackdrop.animated.contains(.off) && !WelcomeBackdrop.animated.contains(.shuffle), "Off and Shuffle are not among the animated ones")
    var a = BackdropRandom(seed: 7), b = BackdropRandom(seed: 7), c = BackdropRandom(seed: 8)
    check((0..<20).map { _ in a.next() } == (0..<20).map { _ in b.next() }, "the same seed gives the same numbers")
    check((0..<20).map { _ in a.next() } != (0..<20).map { _ in c.next() }, "another seed gives other numbers")
    var r = BackdropRandom(seed: 1)
    let units = (0..<2000).map { _ in r.unit() }
    check(units.allSatisfy { $0 >= 0 && $0 < 1 }, "unit() stays in 0 ..< 1")
    check((0..<2000).allSatisfy { _ in r.int(7) < 7 }, "int(n) stays below n")
}

// MARK: - Matrix rain

func matrixChecks() {
    let cell = CGSize(width: 16, height: 19)
    for size in [CGSize(width: 800, height: 600), CGSize(width: 1142, height: 1068), CGSize(width: 2600, height: 1400), CGSize(width: 300, height: 200)] {
        let name = "\(Int(size.width))x\(Int(size.height))"
        let scene = MatrixScene.make(size: size, cell: cell, seed: 42)
        check(!scene.columns.isEmpty && scene.columns.count <= MatrixScene.maxColumns, "matrix \(name): \(scene.columns.count) columns, at most \(MatrixScene.maxColumns)")
        check(scene.columns.allSatisfy { $0.x >= 0 && $0.x + cell.width <= size.width + 0.01 }, "matrix \(name): every column lies inside the window")
        check(scene.columns.allSatisfy { $0.speed >= 70 && $0.speed <= 190 && $0.phase >= 0 && $0.phase < 1 }, "matrix \(name): speeds and phases are in range")
        check(scene.columns.allSatisfy { let s = scene.fallSeconds($0); return s.isFinite && s > 1 && s < 60 }, "matrix \(name): one fall takes between 1 and 60 seconds")
        check(scene.columns.allSatisfy {
            let y = scene.initialCenterY($0)
            return y <= scene.startCenterY($0) && y >= scene.endCenterY($0)
        }, "matrix \(name): the start position lies on the fall")
        check(scene.columns.allSatisfy { Set($0.variantOrder) == Set(0..<MatrixScene.variantsPerLength) && $0.variantSeconds > 0.3 }, "matrix \(name): every column shows every version of its symbols")
    }
    let scene = MatrixScene.make(size: CGSize(width: 800, height: 600), cell: cell, seed: 42)
    check(scene == MatrixScene.make(size: CGSize(width: 800, height: 600), cell: cell, seed: 42), "matrix: one seed, one scene")
    check(scene != MatrixScene.make(size: CGSize(width: 800, height: 600), cell: cell, seed: 43), "matrix: another seed, another scene")
    check(MatrixScene.make(size: CGSize(width: 10, height: 10), cell: cell, seed: 1).columns.isEmpty, "matrix: a window too small for a picture has no columns")
    check(scene.strips.count == MatrixScene.lengths.count && scene.strips.allSatisfy { $0.count == MatrixScene.variantsPerLength }, "matrix: every length has its versions")
    var allDiffer = true, someSame = true
    for (index, variants) in scene.strips.enumerated() {
        let length = MatrixScene.lengths[index]
        check(variants.allSatisfy { $0.count == length }, "matrix: every version of a \(length)-symbol strip has \(length) symbols")
        for pair in zip(variants, variants.dropFirst()) {
            let changed = zip(pair.0, pair.1).filter { $0 != $1 }.count
            if changed == 0 { allDiffer = false }
            if changed == length { someSame = false }
        }
    }
    check(allDiffer, "matrix: each version differs from the one before (the column flickers)")
    check(someSame, "matrix: and keeps some of its symbols (it is not rewritten)")
    check(Set(MatrixScene.alphabet).count == MatrixScene.alphabet.count, "matrix: the alphabet has no repeated symbol")
}

// MARK: - Aurora, bugs, network

func auroraChecks() {
    let scene = AuroraScene.make(seed: 5)
    check(scene == AuroraScene.make(seed: 5), "aurora: one seed, one scene")
    check(scene.blobs.count >= 5 && scene.rays.count >= 20 && scene.stars.count >= 30, "aurora: bands, rays and stars", "\(scene.blobs.count)/\(scene.rays.count)/\(scene.stars.count)")
    check(scene.blobs.allSatisfy { $0.center.x >= 0 && $0.center.x <= 1 && $0.center.y >= 0 && $0.center.y <= 1 && $0.tint < AuroraScene.tintCount && $0.seconds > 5 },
          "aurora: bands lie in the window, use the theme's tints and drift slowly")
    check(scene.blobs.allSatisfy { $0.size.width > 0.2 && $0.size.height > 0.1 && $0.opacity > 0 && $0.opacity < 1 }, "aurora: bands have a size and are translucent")
    check(scene.rays.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.width > 0 && $0.height > 0 && $0.height < 1 && $0.seconds > 1 }, "aurora: rays are inside the window")
    check(scene.stars.allSatisfy { $0.point.x >= 0 && $0.point.x <= 1 && $0.point.y >= 0 && $0.point.y <= 1 && $0.radius > 0 }, "aurora: stars are inside the window")
}

func bugChecks() {
    for size in [CGSize(width: 800, height: 600), CGSize(width: 1142, height: 1068), CGSize(width: 2600, height: 1400)] {
        let name = "\(Int(size.width))x\(Int(size.height))"
        let scene = BugScene.make(size: size, seed: 9)
        check((3...9).contains(scene.colonies.count), "bugs \(name): \(scene.colonies.count) colonies")
        check(scene.colonies.allSatisfy { $0.seconds > 8 && $0.seconds < 200 && $0.phase >= 0 && $0.phase < 1 && !$0.bugs.isEmpty }, "bugs \(name): a crossing takes 8 to 200 seconds")
        let outside: (CGPoint) -> Bool = { $0.x < 0 || $0.y < 0 || $0.x > size.width || $0.y > size.height }
        check(scene.colonies.allSatisfy { outside($0.points.first!) && outside($0.points.last!) }, "bugs \(name): every path starts and ends outside the window")
        check(scene.colonies.allSatisfy { $0.points.allSatisfy { finite($0.x) && finite($0.y) } && $0.polyline.allSatisfy { finite($0.x) && finite($0.y) } }, "bugs \(name): no path point is NaN")
        check(scene.colonies.allSatisfy { colony in
            let reach = CGRect(x: -size.width, y: -size.height, width: size.width * 3, height: size.height * 3)
            return colony.polyline.allSatisfy { reach.contains($0) }
        }, "bugs \(name): no path wanders far from the window")
        check(scene.colonies.allSatisfy { colony in
            let straight = hypot(colony.points.last!.x - colony.points.first!.x, colony.points.last!.y - colony.points.first!.y)
            return colony.pathLength >= straight - 0.5
        }, "bugs \(name): a path is never shorter than the straight line")
        var smoothEnough = true
        for colony in scene.colonies {
            // No point of the path turns back on itself: the angle between neighbouring pieces stays below a right angle.
            var last: CGFloat?
            for index in 1..<colony.polyline.count {
                let from = colony.polyline[index - 1], to = colony.polyline[index]
                guard hypot(to.x - from.x, to.y - from.y) > 0.001 else { continue }
                let heading = atan2(to.y - from.y, to.x - from.x)
                if let last {
                    var turn = abs(heading - last)
                    if turn > .pi { turn = 2 * .pi - turn }
                    if turn > .pi / 2 { smoothEnough = false }
                }
                last = heading
            }
        }
        check(smoothEnough, "bugs \(name): the paths are smooth curves")
        check(scene.colonies.flatMap(\.bugs).contains { $0.kind == .ant } && scene.colonies.flatMap(\.bugs).contains { $0.kind == .ladybug }, "bugs \(name): ants and ladybugs")
        check(scene.colonies.contains { $0.bugs.count >= 3 }, "bugs \(name): the ants march in a line")
        check(scene.colonies.allSatisfy { colony in colony.bugs.allSatisfy { $0.lag >= 0 && colony.startFraction(of: $0) >= 0 && colony.startFraction(of: $0) < 1 } }, "bugs \(name): followers are behind their leader")
    }
    let scene = BugScene.make(size: CGSize(width: 800, height: 600), seed: 9)
    check(scene == BugScene.make(size: CGSize(width: 800, height: 600), seed: 9), "bugs: one seed, one scene")
    let colony = scene.colonies[0]
    let first = colony.sample(0), end = colony.sample(0.9999), wrapped = colony.sample(1.0), beyond = colony.sample(2.25), before = colony.sample(-0.75)
    check(hypot(first.point.x - colony.points[0].x, first.point.y - colony.points[0].y) < 0.01, "bugs: sample(0) is the start of the path")
    check(hypot(end.point.x - colony.points.last!.x, end.point.y - colony.points.last!.y) < 3, "bugs: sample(1) is the end of the path")
    check(hypot(wrapped.point.x - first.point.x, wrapped.point.y - first.point.y) < 0.01, "bugs: the path wraps around")
    let quarter = colony.sample(0.25), viaTwo = colony.sample(2.25), viaMinus = colony.sample(-0.75)
    check(hypot(beyond.point.x - quarter.point.x, beyond.point.y - quarter.point.y) < 0.01 && hypot(before.point.x - quarter.point.x, before.point.y - quarter.point.y) < 0.01
            && viaTwo.heading == beyond.heading && viaMinus.heading == before.heading, "bugs: fractions outside 0 ..< 1 wrap")
    var step = 0.0, maxJump: CGFloat = 0
    var previous = colony.sample(0).point
    while step + 0.002 < 1 {
        step += 0.002
        let point = colony.sample(step).point
        maxJump = max(maxJump, hypot(point.x - previous.x, point.y - previous.y))
        previous = point
    }
    check(maxJump < colony.pathLength * 0.004, "bugs: equal steps along the path move equal distances", "largest \(maxJump) of path \(colony.pathLength)")
    check(BugScene.make(size: CGSize(width: 10, height: 10), seed: 1).colonies.isEmpty, "bugs: a window too small has no colonies")
}

func networkChecks() {
    for size in [CGSize(width: 800, height: 600), CGSize(width: 1142, height: 1068), CGSize(width: 2600, height: 1400)] {
        let name = "\(Int(size.width))x\(Int(size.height))"
        let scene = NetworkScene.make(size: size, seed: 3)
        check(scene.nodes.count >= 8 && scene.nodes.count <= 220, "network \(name): \(scene.nodes.count) nodes")
        check(scene.nodes.allSatisfy { $0.point.x >= 0 && $0.point.x <= size.width && $0.point.y >= 0 && $0.point.y <= size.height }, "network \(name): nodes lie inside the window")
        check(scene.edges.allSatisfy { $0.a < $0.b && $0.b < scene.nodes.count }, "network \(name): every line joins two different nodes")
        check(Set(scene.edges.map { $0.a * scene.nodes.count + $0.b }).count == scene.edges.count, "network \(name): no line twice")
        var linked = Set<Int>()
        for edge in scene.edges { linked.insert(edge.a); linked.insert(edge.b) }
        check(linked.count == scene.nodes.count, "network \(name): every node is on a line")
        check(!scene.pulses.isEmpty && scene.pulses.allSatisfy { $0.edge < scene.edges.count && $0.travel > 0 && $0.idle > 0 && $0.stillFraction > 0 && $0.stillFraction < 1 }, "network \(name): \(scene.pulses.count) pulses run on real lines")
        let longest = scene.edges.map { hypot(scene.nodes[$0.a].point.x - scene.nodes[$0.b].point.x, scene.nodes[$0.a].point.y - scene.nodes[$0.b].point.y) }.max() ?? 0
        let spacing = max(120, sqrt(size.width * size.height / 140))
        check(longest < spacing * 3.5, "network \(name): no line crosses the window", "longest \(Int(longest)) of spacing \(Int(spacing))")
    }
    check(NetworkScene.make(size: CGSize(width: 800, height: 600), seed: 3) == NetworkScene.make(size: CGSize(width: 800, height: 600), seed: 3), "network: one seed, one scene")
    check(NetworkScene.make(size: CGSize(width: 10, height: 10), seed: 1).nodes.isEmpty, "network: a window too small has no nodes")
}

// MARK: - The list of actions

func catalogueChecks() {
    let withGit = WelcomeCatalogue.project(isGitRepo: true), withoutGit = WelcomeCatalogue.project(isGitRepo: false)
    let idsWith = withGit.flatMap { $0.actions.map(\.id) }, idsWithout = withoutGit.flatMap { $0.actions.map(\.id) }
    check(withGit.map(\.section) == WelcomeSection.allCases, "catalogue: Start, Explore and Build & Run, in that order")
    check(Set(idsWith).count == idsWith.count, "catalogue: no action twice")
    check(idsWith.contains(.git) && !idsWithout.contains(.git), "catalogue: Git only for a Git repository")
    check(Set(idsWith).subtracting(idsWithout) == [.git], "catalogue: Git is the only difference")
    check(withGit.allSatisfy { !$0.actions.isEmpty }, "catalogue: no empty section")
    let expected: Set<WelcomeActionID> = [.terminal, .newFeature, .quickFeature, .newBug, .discussions, .tasks, .xray, .understand, .research, .search, .files, .openFile, .git, .deployments, .workflow, .qa, .uiStudio, .browser]
    check(Set(idsWith) == expected, "catalogue: the tiles REQ-001 names", "\(Set(idsWith).symmetricDifference(expected))")
    check(WelcomeCatalogue.emptyWindow.map(\.id) == [.openFolder, .openFile, .newProject], "catalogue: the window without a folder offers Open Folder, Open File, New Project")
    check(Set(idsWith).union(WelcomeCatalogue.emptyWindow.map(\.id)) == Set(WelcomeActionID.allCases), "catalogue: every action id is offered somewhere")
    let all = WelcomeActionID.allCases.map(WelcomeCatalogue.action)
    check(all.allSatisfy { !$0.title.isEmpty && !$0.hint.isEmpty && !$0.symbol.isEmpty && $0.id == WelcomeCatalogue.action($0.id).id }, "catalogue: every action has a title, a hint and an icon")
    check(all.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil }, "catalogue: every icon is a symbol this macOS has",
          all.filter { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) == nil }.map(\.symbol).joined(separator: ","))
    check(withGit[0].actions.first?.isProminent == true && all.filter(\.isProminent).count == 2, "catalogue: Open Terminal (and Open Folder, in its own window) stand out")
    // A shortcut a tile shows must be one the app's menus really have.
    let menus = (try? String(contentsOfFile: "MarkView/App/MarkViewApp.swift")) ?? ""
    for action in all {
        guard let shortcut = action.shortcut, let key = shortcut.last else { continue }
        check(menus.contains("keyboardShortcut(\"\(key.lowercased())\""), "catalogue: \(action.title) shows \(shortcut), which the menus have")
    }
}

// MARK: - Layers

@MainActor func pixels(of image: CGImage) -> (alphaTop: Double, alphaBottom: Double, brightBottom: Double, alphaAll: Double)? {
    let width = image.width, height = image.height
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Memory row 0 is the top of the image.
    func alpha(rows: Range<Int>) -> Double {
        var sum = 0.0
        for row in rows { for column in 0..<width { sum += Double(data[(row * width + column) * 4 + 3]) } }
        return sum / Double(rows.count * width * 255)
    }
    let band = max(1, height / 4)
    let bottomRows = (height - band)..<height
    // The brightest pixel that is mostly opaque (the colours are premultiplied).
    var bright = 0.0
    for row in bottomRows {
        for column in 0..<width {
            let i = (row * width + column) * 4
            guard data[i + 3] > 200 else { continue }
            bright = max(bright, (Double(data[i]) + Double(data[i + 1]) + Double(data[i + 2])) / (3 * 255))
        }
    }
    return (alpha(rows: 0..<band), alpha(rows: bottomRows), bright, alpha(rows: 0..<height))
}

func allLayers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(allLayers) }

@MainActor func layerChecks() {
    let darkColors = BackdropColors(AppPalette(ThemePalette.make(.classicDark)))
    let lightColors = BackdropColors(AppPalette(ThemePalette.make(.classicLight)))
    check(darkColors.isDark && !lightColors.isDark, "colours: the theme says whether it is dark")
    let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .medium)
    let glyphs = Array("ｦｱｳｴｵｶｷｹｺｻｼｽｾﾀﾂﾃﾅﾆ")
    if let image = BackdropBuilder.stripImage(glyphs: glyphs, cell: CGSize(width: 16, height: 19), font: font, colors: darkColors, scale: 2),
       let measured = pixels(of: image) {
        check(image.width == 32 && image.height == 19 * glyphs.count * 2, "strip image: the size of its symbols at 2x", "\(image.width)x\(image.height)")
        check(measured.alphaTop < measured.alphaBottom * 0.5, "strip image: the tail (top) is fainter than the head (bottom)", "top \(measured.alphaTop), bottom \(measured.alphaBottom)")
        check(measured.alphaBottom > 0.03, "strip image: the head is drawn", "\(measured.alphaBottom)")
        check(measured.brightBottom > 0.6, "strip image: the head has a bright pixel", "\(measured.brightBottom)")
    } else {
        check(false, "strip image: it can be drawn")
    }
    for kind in [BugScene.Kind.ant, .ladybug] {
        if let image = BackdropBuilder.bugImage(kind: kind, length: 18, color: .systemGreen, scale: 2), let measured = pixels(of: image) {
            check(measured.alphaAll > 0.1, "bug image: \(kind) is drawn, not empty", "\(measured.alphaAll)")
            check(image.width > 10 && image.height > 10, "bug image: \(kind) has a size", "\(image.width)x\(image.height)")
        } else {
            check(false, "bug image: \(kind) can be drawn")
        }
    }

    for kind in WelcomeBackdrop.animated {
        for (colorName, colors) in [("dark", darkColors), ("light", lightColors)] {
            for size in [CGSize(width: 700, height: 500), CGSize(width: 1142, height: 1068), CGSize(width: 2600, height: 1400)] {
                let label = "\(kind.rawValue) \(colorName) \(Int(size.width))x\(Int(size.height))"
                let moving = BackdropBuilder(size: size, colors: colors, scale: 2, animated: true, seed: 11).layers(for: kind)
                let still = BackdropBuilder(size: size, colors: colors, scale: 2, animated: false, seed: 11).layers(for: kind)
                check(!moving.isEmpty && moving.count <= 1400, "\(label): \(moving.count) layers")
                check(moving.count == still.count, "\(label): the still picture has the same layers")
                let all = moving.flatMap(allLayers), allStill = still.flatMap(allLayers)
                check(all.allSatisfy { finite($0.position.x) && finite($0.position.y) && finite($0.bounds.width) && finite($0.bounds.height) }, "\(label): no layer has a NaN position or size")
                check(allStill.allSatisfy { ($0.animationKeys() ?? []).isEmpty }, "\(label): the still picture has no animation (Reduce Motion)")
                check(all.contains { !($0.animationKeys() ?? []).isEmpty }, "\(label): the moving picture is animated")
                check(all.flatMap { layer in (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) } }.allSatisfy { $0.repeatCount == .infinity && $0.duration > 0 },
                      "\(label): every animation repeats for ever (no timer restarts it)")
                // Whatever is drawn stays near the window: a few layers of a moving scene start outside it by design (matrix strips, bugs).
                let reach = CGRect(x: -size.width, y: -size.height, width: size.width * 3, height: size.height * 3)
                check(allStill.allSatisfy { reach.contains($0.position) || $0 is CAShapeLayer }, "\(label): the still picture stays around the window")
            }
        }
    }
    let matrix = BackdropBuilder(size: CGSize(width: 800, height: 600), colors: darkColors, scale: 2, animated: true, seed: 11).layers(for: .matrix)
    check(matrix.allSatisfy { Set($0.animationKeys() ?? []) == ["fall", "flicker"] }, "matrix: every strip falls and flickers")
    let flicker = matrix.compactMap { $0.animation(forKey: "flicker") as? CAKeyframeAnimation }
    check(flicker.allSatisfy { $0.values?.count == MatrixScene.variantsPerLength && $0.calculationMode == .discrete }, "matrix: the symbols change in steps, not in a blur")
    let fall = matrix.compactMap { $0.animation(forKey: "fall") as? CABasicAnimation }
    check(fall.allSatisfy { ($0.fromValue as? Double ?? 0) > ($0.toValue as? Double ?? 1) }, "matrix: strips move downwards")
    check(Set(fall.map(\.duration)).count > 10, "matrix: strips fall at many different speeds")
    let bugs = BackdropBuilder(size: CGSize(width: 800, height: 600), colors: darkColors, scale: 2, animated: true, seed: 11).layers(for: .bugs)
    let walkers = bugs.compactMap { $0.animation(forKey: "walk") as? CAKeyframeAnimation }
    check(walkers.count == bugs.count && walkers.allSatisfy { $0.rotationMode == .rotateAuto && $0.path != nil && $0.calculationMode == .paced },
          "bugs: every bug walks a path at an even pace and faces the way it goes")
    let stillBugs = BackdropBuilder(size: CGSize(width: 800, height: 600), colors: darkColors, scale: 2, animated: false, seed: 11).layers(for: .bugs)
    check(stillBugs.allSatisfy { abs($0.transform.m11 * $0.transform.m11 + $0.transform.m12 * $0.transform.m12 - 1) < 0.0001 }, "bugs: a still bug is turned, not skewed")
    check(BackdropBuilder(size: CGSize(width: 10, height: 10), colors: darkColors, scale: 2, animated: true, seed: 1).layers(for: .matrix).isEmpty, "a window too small gets no layers")
    check(WelcomeBackdrop.allCases.filter { $0 == .off || $0 == .shuffle }.allSatisfy {
        BackdropBuilder(size: CGSize(width: 800, height: 600), colors: darkColors, scale: 2, animated: true, seed: 1).layers(for: $0).isEmpty }, "Off and Shuffle draw no layers of their own")
}

// MARK: - The hosted screen

@MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

@MainActor func settle(_ view: NSView, seconds: Double = 0.2) {
    for _ in 0..<5 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}

@MainActor func host(project: String?, git: Bool, theme: AppTheme, accent: ThemeColor? = nil, size: NSSize, still: Bool, backdrop: WelcomeBackdrop = .matrix,
                      perform: @escaping (WelcomeActionID) -> Void = { _ in })
    -> (NSWindow, NSHostingView<AnyView>) {
    let screen = WelcomeScreen(projectName: project, isGitRepo: git, backdrop: .constant(backdrop), still: still, perform: perform) {
        if project != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready to resume").font(.system(size: 13, weight: .semibold))
                Text("Project operations: Deploy / Install / Restart buttons from X-Ray Deployment").font(.system(size: 11))
            }
            .padding(12)
            .frame(maxWidth: 700, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.14, green: 0.19, blue: 0.3)))
        } else {
            Text("Recent projects").font(.system(size: 13, weight: .semibold))
        }
    }
    let hosting = NSHostingView(rootView: AnyView(screen.environment(\.palette, AppPalette(ThemePalette.make(theme, accent: accent)))))
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.frame = NSRect(origin: .zero, size: size)
    window.orderFrontRegardless()
    return (window, hosting)
}

@MainActor func snapshot(_ view: NSView, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
}

@MainActor func hostedChecks() {
    // Every backdrop, in a dark and a light theme, in a project window and in a window without a folder.
    for backdrop in WelcomeBackdrop.allCases where backdrop != .shuffle {
        for theme in [AppTheme.classicDark, .classicLight, .midnight] {
            for (project, git, size) in [("MarkView", true, NSSize(width: 1142, height: 1068)), (nil, false, NSSize(width: 900, height: 700)), ("A-long-project-folder-name", false, NSSize(width: 560, height: 800))] as [(String?, Bool, NSSize)] {
                let (window, hosting) = host(project: project, git: git, theme: theme, size: size, still: true, backdrop: backdrop)
                settle(hosting)
                let name = "\(backdrop.rawValue)-\(theme.rawValue)-\(project == nil ? "empty" : (size.width < 600 ? "narrow" : "project"))"
                let views = descendants(hosting)
                let backdropViews = views.compactMap { $0 as? BackdropHostView }
                check(backdropViews.count == (backdrop == .off ? 0 : 1), "\(name): \(backdrop == .off ? "no backdrop view" : "one backdrop view")")
                if let view = backdropViews.first {
                    let layers = (view.layer?.sublayers ?? [])
                    check(!layers.isEmpty, "\(name): the backdrop has \(layers.count) layers", "bounds \(view.bounds)")
                    check(view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)) == nil, "\(name): the backdrop takes no mouse event")
                    let builds = view.buildCount
                    view.configure(kind: backdrop, colors: BackdropColors(AppPalette(ThemePalette.make(theme))), seed: view.currentSeed, still: true)
                    check(view.buildCount == builds, "\(name): an update that changes nothing does not rebuild (the animation keeps running)")
                    check(view.frame.size == hosting.bounds.size, "\(name): the backdrop fills the window")
                }
                snapshot(hosting, name)
                window.close()
            }
        }
    }
}

/// BUG-120: the background belongs to the window that chose it. The screen shows only the binding it is given, so the stored value that
/// the old @AppStorage shared with every window cannot reach it, and two windows hold two different choices at once.
@MainActor func perWindowChecks() {
    let defaults = UserDefaults.standard
    let previous = defaults.object(forKey: WelcomeBackdrop.storageKey)
    defer { if let previous { defaults.set(previous, forKey: WelcomeBackdrop.storageKey) } else { defaults.removeObject(forKey: WelcomeBackdrop.storageKey) } }
    defaults.set(WelcomeBackdrop.aurora.rawValue, forKey: WelcomeBackdrop.storageKey)
    let size = NSSize(width: 900, height: 700)
    let (first, firstHosting) = host(project: "MarkView", git: false, theme: .classicDark, size: size, still: true, backdrop: .network)
    let (second, secondHosting) = host(project: "MarkView", git: false, theme: .classicDark, size: size, still: true, backdrop: .bugs)
    defer { first.close(); second.close() }
    settle(firstHosting); settle(secondHosting)
    let kinds = [firstHosting, secondHosting].map { descendants($0).compactMap { $0 as? BackdropHostView }.first?.currentKind }
    check(kinds == [.network, .bugs], "per window: two windows show two different backgrounds at the same time", "\(kinds)")
    check(kinds.allSatisfy { $0 != .aurora }, "per window: the stored value other windows may have written does not change a window that has its own")
    // A third window that chose Off stays empty while the others animate.
    let (third, thirdHosting) = host(project: "MarkView", git: false, theme: .classicDark, size: size, still: true, backdrop: .off)
    defer { third.close() }
    settle(thirdHosting)
    check(descendants(thirdHosting).compactMap { $0 as? BackdropHostView }.isEmpty, "per window: a window that chose Off draws nothing while the others animate")
}

/// Real motion, without a screen: a window that is ordered in (far outside every display) lets Core Animation compute the presentation
/// layer, the values the render server shows. Two readings a moment apart must differ the way the animation says.
@MainActor func motionChecks() {
    for backdrop in [WelcomeBackdrop.matrix, .bugs, .aurora, .network] {
        let (window, hosting) = host(project: "MarkView", git: false, theme: .classicDark, size: NSSize(width: 1000, height: 800), still: false, backdrop: backdrop)
        settle(hosting)
        guard let view = descendants(hosting).compactMap({ $0 as? BackdropHostView }).first, let root = view.layer else {
            check(false, "motion \(backdrop.rawValue): the backdrop view exists"); window.close(); continue
        }
        check(view.isAnimating, "motion \(backdrop.rawValue): the view animates (Reduce Motion is off in this session)")
        func readings() -> [CGPoint] {
            CATransaction.flush()
            return (root.sublayers ?? []).prefix(400).map { $0.presentation()?.position ?? CGPoint(x: -1e9, y: -1e9) }
        }
        let first = readings()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let second = readings()
        let moved = zip(first, second).filter { abs($0.x - $1.x) > 0.5 || abs($0.y - $1.y) > 0.5 }
        check(first.allSatisfy { $0.x > -1e8 }, "motion \(backdrop.rawValue): every layer has a presentation layer")
        check(!moved.isEmpty, "motion \(backdrop.rawValue): \(moved.count) of \(first.count) layers moved in 0.6 seconds")
        if backdrop == .matrix {
            // Every strip either fell straight down, or left the bottom edge in these 0.6 seconds and came back in at the top.
            var falls: [CGFloat] = []
            var wrapped = 0
            for (before, after) in zip(first, second) {
                if abs(before.x - after.x) > 0.01 { continue }
                if before.y - after.y > 0 { falls.append((before.y - after.y) / 0.6) } else if after.y - before.y > 200 { wrapped += 1 }
            }
            let slowest = Int(falls.min() ?? 0), fastest = Int(falls.max() ?? 0)
            check(falls.count + wrapped == first.count && wrapped < first.count / 4, "motion matrix: strips fall straight down (\(falls.count) of \(first.count), \(wrapped) came round again), \(slowest) to \(fastest) points a second")
            check((falls.min() ?? 0) > 60 && (falls.max() ?? 0) < 200, "motion matrix: the speeds are the scene's (70 to 190 points a second)")
        }
        window.close()
    }
}

/// A window that is resized gets a backdrop of its new size, and not a rebuild for every pixel on the way.
@MainActor func resizeChecks() {
    let (window, hosting) = host(project: "MarkView", git: false, theme: .classicDark, size: NSSize(width: 700, height: 600), still: false)
    defer { window.close() }
    settle(hosting)
    guard let view = descendants(hosting).compactMap({ $0 as? BackdropHostView }).first else { check(false, "resize: the backdrop view exists"); return }
    let first = view.buildCount
    check(view.builtSize == CGSize(width: 700, height: 600), "resize: built for the first size", "\(view.builtSize)")
    // Twenty small steps, as a drag of the window edge makes them.
    for step in 1...20 {
        window.setContentSize(NSSize(width: 700 + CGFloat(step) * 20, height: 600 + CGFloat(step) * 15))
        hosting.frame = NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    check(view.buildCount - first <= 2, "resize: a drag does not rebuild on every step (\(view.buildCount - first) builds in 20 steps)")
    settle(hosting, seconds: 0.2)
    check(view.builtSize == CGSize(width: 1100, height: 900) && view.bounds.size == view.builtSize, "resize: once the size has settled the backdrop is built for it", "built \(view.builtSize), view \(view.bounds.size)")
    let tops = (view.layer?.sublayers ?? []).compactMap { ($0.animation(forKey: "fall") as? CABasicAnimation)?.fromValue as? Double }
    check(!tops.isEmpty && tops.allSatisfy { $0 > 900 }, "resize: the strips now start above the new, taller window")
}

/// The tiles really run what they are given: real mouse clicks on a grid of points over the hosted window (a window that is ordered
/// in, far outside every display), and every action of the catalogue must fire from some point.
@MainActor func tileChecks() {
    // With a backdrop drawn, so the check also proves that the backdrop lets every click through.
    for (git, project) in [(true, "MarkView"), (false, "MarkView"), (false, nil)] as [(Bool, String?)] {
        var performed: [WelcomeActionID] = []
        let size = NSSize(width: 1000, height: 1100)
        let (window, hosting) = host(project: project, git: git, theme: .classicDark, size: size, still: true) { performed.append($0) }
        defer { window.close() }
        settle(hosting)
        func click(_ p: CGPoint) {
            let location = hosting.convert(NSPoint(x: p.x, y: p.y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                window.sendEvent(event)
            }
        }
        var fired = Set<WelcomeActionID>()
        var y: CGFloat = 20
        // The Background menu sits in the bottom right corner; clicking it would open a menu that waits for a choice.
        while y < size.height - 90 {
            var x: CGFloat = 20
            while x < size.width - 20 {
                let before = performed.count
                click(CGPoint(x: x, y: y))
                if performed.count > before { fired.formUnion(performed[before...]) }
                x += 13
            }
            y += 13
        }
        let expected: Set<WelcomeActionID> = project == nil
            ? Set(WelcomeCatalogue.emptyWindow.map(\.id))
            : Set(WelcomeCatalogue.project(isGitRepo: git).flatMap { $0.actions.map(\.id) })
        let name = project == nil ? "a window without a folder" : (git ? "a Git project" : "a project that is not a Git repository")
        check(fired == expected, "tiles, \(name): a click reaches exactly the \(expected.count) tiles of the catalogue", "missing \(expected.subtracting(fired).map(\.rawValue).sorted()), extra \(fired.subtracting(expected).map(\.rawValue).sorted())")
    }
}


// MARK: - Frames Core Animation really composes

/// The presentation layer tree (what the render server shows now, animations applied) drawn into a bitmap.
@MainActor func presentationImage(_ root: CALayer, size: CGSize, background: NSColor) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(background.cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    (root.presentation() ?? root).render(in: context)
    return context.makeImage()
}

/// The share of pixels that differ between two pictures of the same size.
func differingShare(_ a: CGImage, _ b: CGImage) -> Double {
    let width = a.width, height = a.height
    guard b.width == width, b.height == height, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return 0 }
    func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }
    let first = bytes(a), second = bytes(b)
    var differing = 0
    for pixel in 0..<(width * height) where abs(Int(first[pixel * 4]) - Int(second[pixel * 4])) + abs(Int(first[pixel * 4 + 1]) - Int(second[pixel * 4 + 1]))
        + abs(Int(first[pixel * 4 + 2]) - Int(second[pixel * 4 + 2])) > 24 { differing += 1 }
    return Double(differing) / Double(width * height)
}

func savePNG(_ image: CGImage, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
}

func angleBetween(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    var difference = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
    if difference > .pi { difference = 2 * .pi - difference }
    return difference
}

@MainActor func animatedFrameChecks() {
    let size = NSSize(width: 1000, height: 800)
    for backdrop in [WelcomeBackdrop.matrix, .bugs, .aurora, .network] {
        let (window, hosting) = host(project: "MarkView", git: false, theme: .classicDark, size: size, still: false, backdrop: backdrop)
        defer { window.close() }
        settle(hosting)
        guard let view = descendants(hosting).compactMap({ $0 as? BackdropHostView }).first, let root = view.layer else {
            check(false, "frames \(backdrop.rawValue): the backdrop view exists"); continue
        }
        let background = NSColor(AppPalette(ThemePalette.make(.classicDark)).model.bg)
        CATransaction.flush()
        guard let early = presentationImage(root, size: view.bounds.size, background: background) else { check(false, "frames \(backdrop.rawValue): a frame can be drawn"); continue }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        CATransaction.flush()
        guard let late = presentationImage(root, size: view.bounds.size, background: background) else { check(false, "frames \(backdrop.rawValue): a second frame can be drawn"); continue }
        savePNG(early, "frame-\(backdrop.rawValue)-0.0s")
        savePNG(late, "frame-\(backdrop.rawValue)-1.5s")
        let share = differingShare(early, late)
        check(share > 0.002, "frames \(backdrop.rawValue): the composed picture changes in 1.5 seconds (\(String(format: "%.1f", share * 100)) % of the pixels)")
        let lit = differingShare(late, { () -> CGImage in
            let context = CGContext(data: nil, width: late.width, height: late.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: late.width, height: late.height))
            return context.makeImage()!
        }())
        check(lit > 0.005, "frames \(backdrop.rawValue): the frame is not the empty background (\(String(format: "%.1f", lit * 100)) % drawn)")

        if backdrop == .bugs {
            // Facing: a bug's presentation transform must turn it to where its position moves.
            func state() -> [(CGPoint, CGFloat)] {
                CATransaction.flush()
                return (root.sublayers ?? []).compactMap { layer in
                    guard let presentation = layer.presentation() else { return nil }
                    let t = presentation.transform
                    return (presentation.position, atan2(t.m12, t.m11))
                }
            }
            let before = state()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let after = state()
            var aligned = 0, compared = 0
            for (a, b) in zip(before, after) {
                let dx = b.0.x - a.0.x, dy = b.0.y - a.0.y
                guard hypot(dx, dy) > 3, hypot(dx, dy) < 60 else { continue }
                compared += 1
                if angleBetween(atan2(dy, dx), (a.1 + b.1) / 2) < 0.3 { aligned += 1 }
            }
            check(compared >= before.count * 7 / 10 && aligned == compared, "frames bugs: every bug in motion faces the way it moves (\(aligned) of \(compared), \(before.count) bugs)")
        }
        if backdrop == .matrix {
            // The symbols change while a strip falls: a layer's picture is a different one a little later, and the same one a moment later.
            func pictures() -> [CGImage?] { CATransaction.flush(); return (root.sublayers ?? []).map { $0.presentation()?.contents as! CGImage? } }
            let start = pictures()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            let blink = pictures()
            var changedLater = Set<Int>()
            var samples = [start]
            for _ in 0..<6 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                samples.append(pictures())
            }
            for later in samples.dropFirst() { for (index, picture) in later.enumerated() where picture !== start[index] { changedLater.insert(index) } }
            let sameSoon = zip(start, blink).filter { $0 === $1 }.count
            check(sameSoon >= start.count * 8 / 10, "frames matrix: a strip keeps its symbols for a moment (\(sameSoon) of \(start.count) unchanged after 0.04 s)")
            check(changedLater.count >= start.count * 9 / 10, "frames matrix: and its symbols change within 2.5 seconds (\(changedLater.count) of \(start.count) strips)")
        }
    }
}

/// Reduce Motion: with the system setting on, the screen must hold still; off again, it moves. The setting is read through
/// NSWorkspace, so the check swaps that one getter for the length of the run and announces the change as the system does.
@MainActor func reduceMotionChecks() {
    let selector = NSSelectorFromString("accessibilityDisplayShouldReduceMotion")
    guard let method = class_getInstanceMethod(NSWorkspace.self, selector) else { check(false, "reduce motion: the system getter exists"); return }
    let original = method_getImplementation(method)
    var reduce = false
    let replacement: @convention(block) (AnyObject) -> Bool = { _ in reduce }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
    defer { method_setImplementation(method, original) }
    let (window, hosting) = host(project: "MarkView", git: false, theme: .classicDark, size: NSSize(width: 900, height: 700), still: false, backdrop: .bugs)
    defer { window.close() }
    settle(hosting)
    guard let view = descendants(hosting).compactMap({ $0 as? BackdropHostView }).first, let root = view.layer else { check(false, "reduce motion: the backdrop view exists"); return }
    func animated() -> Int { (root.sublayers ?? []).flatMap { [$0] + ($0.sublayers ?? []) }.filter { !($0.animationKeys() ?? []).isEmpty }.count }
    check(!reduce && view.isAnimating && animated() > 0, "reduce motion off: the bugs are animated (\(animated()) layers)")
    reduce = true
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    settle(hosting)
    check(!view.isAnimating && animated() == 0 && !(root.sublayers ?? []).isEmpty, "reduce motion on: the same scene stands still, nothing is animated (\((root.sublayers ?? []).count) layers)")
    let still = presentationImage(root, size: view.bounds.size, background: .black)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    CATransaction.flush()
    if let still, let later = presentationImage(root, size: view.bounds.size, background: .black) {
        check(differingShare(still, later) == 0, "reduce motion on: two pictures 0.8 seconds apart are the same")
    }
    reduce = false
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    settle(hosting)
    check(view.isAnimating && animated() > 0, "reduce motion off again: the bugs move again (\(animated()) layers)")
}

/// How the screen looks in Boris's theme as his screenshot shows it (dark, green accent), at the size of that window.
@MainActor func borisThemeSnapshot() {
    for backdrop in [WelcomeBackdrop.matrix, .aurora, .bugs, .network] {
        let (window, hosting) = host(project: "vivaa-internals", git: true, theme: .midnight, accent: ThemeColor(0x3FB950), size: NSSize(width: 1142, height: 1068), still: true, backdrop: backdrop)
        settle(hosting)
        snapshot(hosting, "boris-\(backdrop.rawValue)")
        window.close()
    }
}

// MARK: - The Background pill never sits on a tile

/// The accessibility elements under a view, with their screen frames (SwiftUI builds the tree once an assistive client is assumed).
@MainActor func accessibilityButtons(_ root: NSObject, depth: Int = 0) -> [(label: String, frame: NSRect)] {
    // SwiftUI's accessibility nodes answer the NSAccessibility selectors without declaring the protocol, so they are asked by selector.
    func value(_ object: NSObject, _ key: String) -> Any? { object.responds(to: Selector((key))) ? object.value(forKey: key) : nil }
    guard depth < 16, let children = value(root, "accessibilityChildren") as? [NSObject] else { return [] }
    var found: [(String, NSRect)] = []
    for child in children {
        let role = value(child, "accessibilityRole") as? String
        let label = (value(child, "accessibilityLabel") as? String) ?? (value(child, "accessibilityTitle") as? String) ?? ""
        if !label.isEmpty, role == NSAccessibility.Role.button.rawValue || role == NSAccessibility.Role.menuButton.rawValue || role == NSAccessibility.Role.popUpButton.rawValue,
           let frame = value(child, "accessibilityFrame") as? NSValue {
            found.append((label, frame.rectValue))
        }
        found += accessibilityButtons(child, depth: depth + 1)
    }
    return found
}

/// Found in the running app (5.53.0): in a pane narrower or shorter than the tile list, the pill pinned to the window's corner covered the last
/// visible tile. It now sits beside the app icon inside the scrolled column.
@MainActor func pillChecks() {
    NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let titles = Set(WelcomeCatalogue.project(isGitRepo: true).flatMap { $0.actions.map(\.title) })
    for size in [NSSize(width: 520, height: 520), NSSize(width: 620, height: 800), NSSize(width: 1000, height: 640), NSSize(width: 460, height: 900)] {
        let (window, hosting) = host(project: "MarkView", git: true, theme: .classicDark, size: size, still: true)
        settle(hosting, seconds: 0.3)
        // SwiftUI builds its accessibility tree on the first question of an assistive client and fills it in over the next turns.
        _ = accessibilityButtons(hosting)
        settle(hosting, seconds: 0.4)
        let buttons = accessibilityButtons(hosting)
        let pill = buttons.first { $0.label.contains("Matrix Rain") }
        let tiles = buttons.filter { titles.contains($0.label) }
        check(pill != nil, "pill \(Int(size.width))x\(Int(size.height)): the Background pill is found in the accessibility tree")
        check(tiles.count >= 4, "pill \(Int(size.width))x\(Int(size.height)): tiles are found too (\(tiles.count))")
        if let pill {
            let covered = tiles.filter { $0.frame.intersects(pill.frame.insetBy(dx: 1, dy: 1)) }.map(\.label)
            check(covered.isEmpty, "pill \(Int(size.width))x\(Int(size.height)): the pill covers no tile (covers: \(covered))")
        }
        window.close()
    }
}

choiceChecks()
matrixChecks()
auroraChecks()
bugChecks()
networkChecks()
catalogueChecks()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    layerChecks()
    hostedChecks()
    perWindowChecks()
    motionChecks()
    resizeChecks()
    tileChecks()
    pillChecks()
    animatedFrameChecks()
    reduceMotionChecks()
    borisThemeSnapshot()
}
print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
