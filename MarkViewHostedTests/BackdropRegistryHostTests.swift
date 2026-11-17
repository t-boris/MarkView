import AppKit
import QuartzCore
import XCTest
@testable import MarkView

#if MARKVIEW_BACKDROP_FIXTURE
final class BackdropRegistryHostTests: XCTestCase {
    @MainActor func testRuntimeDiscovery() {
        func check(_ ok: Bool, _ message: String, _ detail: String = "") {
            if !ok { XCTFail(detail.isEmpty ? message : message + " — " + detail) }
        }
func backdrop(_ id: String) -> WelcomeBackdrop { WelcomeBackdrop(rawValue: id)! }
func isFake(_ backdrop: WelcomeBackdrop) -> Bool { backdrop.rawValue.hasPrefix("fake-") }

let colors = BackdropColors(background: .black, bright: .white, dim: .gray, green: .green, cyan: .cyan, purple: .purple, blue: .blue,
                            orange: .orange, red: .red, yellow: .yellow, isDark: true)
func builder(seed: UInt64 = 7, detail: Int = 1) -> BackdropBuilder {
    BackdropBuilder(size: CGSize(width: 800, height: 600), colors: colors, scale: 2, animated: true, seed: seed, detail: detail)
}

// MARK: - What the app registers

/// The names and titles builds before the registry stored and showed; stored values and the picker must not change.
let expectedScenes: [(id: String, title: String, symbol: String)] = [
    ("matrix", "Matrix Rain", "chevron.left.forwardslash.chevron.right"), ("aurora", "Aurora", "sparkles"), ("bugs", "Bug Swarm", "ladybug"),
    ("network", "Network", "point.3.connected.trianglepath.dotted"), ("orbit", "Orbit", "atom"), ("blueprint", "Device Lab", "iphone"),
    ("circuit", "Circuit Flow", "cpu"), ("garden", "Code Garden", "leaf"), ("launch", "Launch", "paperplane"),
    ("gitflow", "Git Flow", "arrow.triangle.branch"), ("typewriter", "Typewriter", "text.cursor"), ("deepsea", "Deep Sea", "water.waves"),
    ("warp", "Warp", "moon.stars")]
let expectedModes: [(id: String, title: String, symbol: String)] = [
    ("project", "By Project", "folder.badge.gearshape"), ("shuffle", "Shuffle", "shuffle"), ("off", "Off", "circle.slash")]

let everything = WelcomeBackdrop.all
let builtIn = everything.filter { !isFake($0) }
check(builtIn.map(\.rawValue) == (expectedScenes + expectedModes).map(\.id), "the picker lists the 13 scenes and then By Project, Shuffle and Off, under the names stored before the registry",
      "\(builtIn.map(\.rawValue))")
check(builtIn.map { [$0.title, $0.symbol] } == (expectedScenes + expectedModes).map { [$0.title, $0.symbol] }, "every backdrop keeps its title and symbol")
check(Set(everything.map(\.rawValue)).count == everything.count && Set(everything.map(\.title)).count == everything.count, "every backdrop has its own stored name and its own title")
check(BackdropRegistry.entries.filter { $0.descriptor.category == .mode }.map(\.descriptor.id) == expectedModes.map(\.id), "the modes are By Project, Shuffle and Off")
check(WelcomeBackdrop.animated.filter { !isFake($0) }.map(\.rawValue) == expectedScenes.map(\.id), "Shuffle picks from the 13 animated scenes, in the order of the picker")
check(builtIn.filter { $0 != .project && $0 != .shuffle && $0 != .off }.allSatisfy { BackdropRegistry.entry($0.rawValue)?.type is any BackdropDrawing.Type },
      "every scene that is registered also draws")
check(builder().layers(for: .project).isEmpty && builder().layers(for: .shuffle).isEmpty && builder().layers(for: .off).isEmpty, "the modes draw no layers of their own")
check(expectedScenes.allSatisfy { !builder().layers(for: backdrop($0.id)).isEmpty }, "every registered scene builds layers")

// MARK: - A backdrop that is only registered

check(everything.contains(backdrop("fake-scene")) && everything.contains(backdrop("fake-still")), "a registered backdrop is in the picker list")
let scenesEnd = everything.firstIndex(of: .project) ?? -1
check(everything.firstIndex(of: backdrop("fake-scene")).map { $0 > everything.firstIndex(of: backdrop("warp"))! && $0 < scenesEnd } == true
      && everything.firstIndex(of: backdrop("fake-still"))! > everything.firstIndex(of: backdrop("fake-scene"))!, "…after the other scenes, before the modes, by its order number")
check(backdrop("fake-scene").title == "Fake Scene" && backdrop("fake-scene").symbol == "star", "…with its own title and symbol")
check(WelcomeBackdrop.animated.contains(backdrop("fake-scene")) && !WelcomeBackdrop.animated.contains(backdrop("fake-still")), "an animated one is in Shuffle's pool, a still one is not")
let shuffled = Set((0..<WelcomeBackdrop.animated.count * 2).map { WelcomeBackdrop.shuffle.scene(pick: $0) })
check(shuffled.contains(backdrop("fake-scene")) && !shuffled.contains(backdrop("fake-still")) && !shuffled.contains(.off) && !shuffled.contains(.shuffle),
      "Shuffle reaches the registered scene and never a still one, a mode or itself", "\(shuffled.map(\.rawValue).sorted())")
check(WelcomeBackdrop.shuffle.scene(pick: -1) == WelcomeBackdrop.animated.last && WelcomeBackdrop.shuffle.scene(pick: WelcomeBackdrop.animated.count) == WelcomeBackdrop.animated.first,
      "Shuffle wraps its number around the pool")
let drawn = builder(seed: 5, detail: 3).layers(for: backdrop("fake-scene"))
check(drawn.count == 1 && drawn.first?.name == "fake-scene-5-3", "the builder dispatches a registered scene to its own drawing, with the builder's seed and detail", "\(drawn.map { $0.name ?? "-" })")
check(builder().layers(for: backdrop("fake-undrawn")).isEmpty && WelcomeBackdrop.all.contains(backdrop("fake-undrawn")), "a registration without a drawing is listed and draws nothing")
let tiny = BackdropBuilder(size: CGSize(width: 10, height: 10), colors: colors, scale: 2, animated: true, seed: 1)
check(tiny.layers(for: backdrop("fake-scene")).isEmpty && !builder().layers(for: backdrop("fake-scene")).isEmpty, "a window too small gets no layers, for a registered scene too")
check(WelcomeBackdrop.stored("fake-scene") == backdrop("fake-scene") && WelcomeBackdrop.stored("fake-scene").scene(pick: 3) == backdrop("fake-scene"), "a registered name is read back and drawn as itself")

// MARK: - By Project from the registrations

func context(_ identity: String, platform: ProjectBackdropSignals.Platform = .unknown, bugs: Int = 0, features: Int = 0, completed: Int = 0, sourceFiles: Int = 0) -> ProjectBackdropContext {
    ProjectBackdropContext(identity: identity, signals: ProjectBackdropSignals(platform: platform, sourceFiles: sourceFiles, inspected: true),
                           openBugs: bugs, criticalBugs: 0, features: features, completedFeatures: completed)
}
check(context("/p/ios", platform: .ios).scene == backdrop("blueprint") && context("/p/ios", platform: .ios, bugs: 9).scene == backdrop("bugs"), "By Project: the rules of the scenes are tried in their priority order")
check(context("/p/api", platform: .backend).scene == backdrop("circuit") && context("/p/big", sourceFiles: 200).scene == backdrop("orbit"), "By Project: each scene decides for itself")
check(context("/p/done", features: 3, completed: 3).scene == backdrop("launch"), "By Project: all features completed, no open bugs, draws Launch")
check(context("/p/new").scene == backdrop("garden") && WelcomeBackdrop.project.scene(pick: 1) == backdrop("garden"), "By Project: the scene without a condition is the default, also for a window without a project")
let fakeProject = context("fake-project", platform: .ios, bugs: 20, features: 4)
check(fakeProject.scene == backdrop("fake-project") && WelcomeBackdrop.project.scene(pick: 1, project: fakeProject) == backdrop("fake-project"),
      "By Project: a registered scene with a rule is drawn when its rule matches, before the others")
check(fakeProject.reason == "Fake Project: 4 features" && fakeProject.summary.hasPrefix("Fake Project"), "…and gives its own reason and title", fakeProject.reason)
check(context("/p/ios", platform: .ios).scene == backdrop("blueprint"), "…and does not change the other projects")
check(context("/p/ios", platform: .ios, bugs: 9).reason.hasPrefix("Bug Swarm: 9 open bugs") && context("/p/ios", platform: .ios).reason == "Device Lab: iOS application", "the reasons are the ones the screen showed before")
let defaults = BackdropRegistry.projectRules.filter { $0.descriptor.project?.matches == nil && !isFake(WelcomeBackdrop(rawValue: $0.descriptor.id)!) }
check(defaults.map(\.descriptor.id) == ["garden"] && BackdropRegistry.projectDefault?.descriptor.id == "garden", "exactly one built-in scene is the default of By Project")
let priorities = BackdropRegistry.projectRules.compactMap { $0.descriptor.project?.priority }
check(Set(priorities).count == priorities.count, "no two rules share a priority, so their order never depends on anything else")

// MARK: - Stored names

check(WelcomeBackdrop.stored(nil).rawValue == "matrix" && WelcomeBackdrop.stored("bogus").rawValue == "matrix" && WelcomeBackdrop(rawValue: "bogus") == nil,
      "a missing or unknown stored name is Matrix Rain")
check((expectedScenes + expectedModes).allSatisfy { WelcomeBackdrop.stored($0.id).rawValue == $0.id }, "every name an earlier build stored is read back as itself")


    }
}
#endif
