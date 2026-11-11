# Welcome backgrounds

The welcome tab offers nine vector animations: Matrix Rain, Aurora, Bug Swarm,
Network, Orbit, Device Lab, Circuit Flow, Code Garden and Launch. Shuffle picks
one on appearance. Off removes the backdrop. By Project derives a scene from
local evidence, with a stable composition for that project's root path.

## Rendering

`WelcomeBackdrop.swift` defines the stored choices and the existing seeded scenes.
`BackdropLayerBuilders.swift` builds the four original scenes;
`ProjectBackdropLayers.swift` adds orbital ellipses and planets, phone wireframes
with scanning light, chip traces with moving packets, anchored leaves and glowing
buds, and rockets with exhaust and a star field. All movement is Core Animation;
there is no SwiftUI frame timer or display link.

`WelcomeBackdropView` owns the layer tree, debounces resizing, rebuilds on theme
or scale changes and respects Reduce Motion. Its NSView never handles hit tests.
Every new scene has a still composition and bounded layer counts. Existing action
tiles retain their nearly opaque fills. The background menu follows the window's
light/dark appearance.

## Project mode

`ProjectWelcomeScreen` observes the existing `FeatureStore`, so bug and feature
updates feed the scene without a second polling loop. Completed/cancelled statuses
come from that project's workflow, including custom names. Unknown statuses are
conservatively counted as open. Cancelled features are excluded from completion.

`ProjectBackdropScanner` runs in a cancellable utility task on project-mode entry
and project changes. It inspects at most 2,500 entries, to five directory levels,
and reads at most 32 KiB of each recognized manifest. It skips hidden files,
symlinks, dependencies, build output and test fixtures. It keeps only platform
hints and source/module counts; it retains no source text and calls no AI or
external service. A truncated scan is labelled sampled. These are visual hints,
not a code-quality or complexity assessment.

The selection rules, in priority order:

1. At least eight open bugs or two critical/blocker bugs: Bug Swarm.
2. iOS/Android evidence: Device Lab.
3. At least 160 source files, eight module signals or 20 features: Orbit.
4. Web/backend evidence: Circuit Flow.
5. All non-cancelled features completed and no open bugs: Launch.
6. Otherwise: Code Garden, also the empty-window fallback.

The header displays the scene, platform and loaded issue counts; the tooltip
explains the selection. Density is capped at four levels; busy projects add
orbits, packets, plants/rockets or bug colonies. The project path hashes to a
stable seed, so the same project retains its composition across restarts and
scene changes. Cached scan results never describe a different project, and a
cancelled scan cannot overwrite a new one.

The default and previously stored choices remain unchanged. `PanelLayout` owns
the choice per window; `WindowSession` persists its raw string. No stored-data
migration or additional permission is needed.

## Verification

`tools/tests/project-backdrop-tests.sh` checks the selection rules, seeds, restore
values, manifest detection, excluded trees, symlinks, read/entry budgets and
cancellation. `tools/tests/welcome-screen-tests.sh` compiles the shipping views
and checks all scenes in dark/light/narrow layouts, actual presentation-layer
motion and rendered changing frames, live context changes, click-through behavior,
window independence, resizing, Reduce Motion and Accessibility scrolling.

For render review, create a directory and pass `SNAPSHOT_DIR=/absolute/path` to
the welcome suite. Scene generation uses a fixed seed in the harness so images
and motion checks are reproducible; the app uses random manual scenes and stable
project scenes. Motion-direction checks use circular angle averaging across the
minus-pi/plus-pi boundary.
