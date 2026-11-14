# CI build performance

The target is at most five minutes for the complete Build & Release workflow.
Since 2026-11-14 the app and installer target Apple Silicon only. Runner queue
delays and cold builds can still exceed the target.

## Current implementation

`.github/workflows/build-release.yml` builds arm64 on one standard macOS
runner. Swift uses optimized incremental compilation (`-O`) for CI. Installer
builds retain the project's whole-module optimization. Ordinary CI app builds
skip the bundled Cockpit runtime; a dedicated Cockpit check builds and tests it,
and the signed release explicitly includes it.

DerivedData is cached separately by architecture and Xcode build version. An
exact cache key also includes the application, Xcode project and project.yml
contents. A changed input set can restore the previous compatible cache.
`tools/ci/build-cache-mtimes.py` restores source timestamps only when SHA-256
content matches the cached manifest, allowing Xcode to reuse unchanged inputs.
Changed inputs keep their checkout timestamps and are rebuilt by Xcode.

The manual `verify_cache=true` input temporarily changes WindowTitle.swift
before restoring source timestamps. Verification builds never save their
modified outputs to the cache:

```sh
gh workflow run build-release.yml --ref main -f verify_cache=true
```

## Evidence

| Case | Result | Evidence |
| --- | --- | --- |
| Original universal whole-module build | Compilation alone took 18:38 | [Baseline run](https://github.com/t-boris/MarkView/actions/runs/41900237060) |
| Initial cache population | Both jobs succeeded; arm64 job took 7:26, excluding its queue wait | [First attempt](https://github.com/t-boris/MarkView/actions/runs/41945571979/attempts/1) |
| Same inputs on fresh runners | Complete workflow approximately 1:25 | [Second attempt](https://github.com/t-boris/MarkView/actions/runs/41945571979/attempts/2) |
| Changed Swift input, previous cache | Complete workflow 1:20; logs show WindowTitle.swift compiled for both architectures and 405 unchanged inputs restored | [Verification run](https://github.com/t-boris/MarkView/actions/runs/41947055788) |
| Previous two-architecture configuration | Complete workflow 1:04; both architectures succeeded | [Main run](https://github.com/t-boris/MarkView/actions/runs/41949405510) |
| Apple Silicon only | Build step 1:08; runner work 1:44; 5:34 waiting for a runner | [PR run](https://github.com/t-boris/MarkView/actions/runs/43532575855) |

Workflow duration uses creation to final completion, including runner setup and
queue delay. Individual job durations are identified separately above. These
measurements establish fast cached builds, not a five-minute upper bound for
all source changes, cache misses, toolchain updates or runner queue delays.

## Experiments already evaluated

- Splitting architectures and replacing whole-module optimization with optimized
  incremental compilation reduced the original approximately 20-minute build,
  but cold builds on standard ARM runners still took approximately 6–9 minutes.
- `xcodebuild -jobs 5` did not change the Swift driver's `-j3` setting.
- Forcing Swift `-j5` did not bring both architecture jobs under five minutes.
- Standard Intel runners exceeded the target and were slower in this trial.
- Three larger Swift batches still took over seven minutes for arm64 and over
  eight minutes for x86_64 ([run](https://github.com/t-boris/MarkView/actions/runs/41947380040)).
- The standard Xcode 27 image also exceeded six minutes without finishing both
  jobs; the experimental run was cancelled and the image selection reverted.
- A local Xcode 27 profile of function-body type checking found no single large
  type-checking stall: the two slowest bodies took approximately 1.85 and 1.81
  seconds. This local profile does not establish CI compiler optimization costs.

All unsuccessful workflow experiments were reverted. Avoid repeating them
without a new hypothesis or changed runner/compiler conditions.

## Remaining infrastructure decision

The repository owner is the personal account `t-boris`. GitHub's larger hosted
runners are available only to organizations and enterprises on Team or
Enterprise Cloud plans. They are billed even for public repositories. A larger
runner therefore requires an infrastructure/account decision, rather than
simply changing this repository's runner label.

A dedicated Mac runner is another option to benchmark. Neither moving the
repository, enabling paid runners nor registering a self-hosted runner has been
authorized or performed. A faster machine must still be measured before claiming
that cold builds meet the target.

References: [larger runner availability](https://docs.github.com/en/actions/concepts/runners/larger-runners),
[runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing).
