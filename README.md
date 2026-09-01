# MetalMatrix Screen Saver

MetalMatrix is a Swift/Metal macOS screen saver that recreates the classic
GLMatrix effect for Apple Silicon and Intel Macs.

The renderer is based on the original `xscreensaver` GLMatrix behavior:

- `matrix3.xpm` glyph atlas
- strip/spinner/wave state machine
- fog, panning, additive blending, and perspective camera
- Matrix, binary, hexadecimal, and DNA encoding modes

The bundle identifier and product name are intentionally different from the
legacy OpenGL saver so both can coexist during testing.

## Compatibility

- macOS 11 Big Sur or later
- Apple Silicon (`arm64`) and Intel (`x86_64`)

Release bundles are universal binaries. The declared minimum system version and
the Mach-O deployment target are both validated as macOS 11.0 during release
builds.

## Build

```sh
./script/build_saver.sh
```

The build output is:

```text
dist/MetalMatrix.saver
```

By default the script builds a universal `arm64 + x86_64` Mach-O bundle. To build only one architecture:

```sh
ARCHS=arm64 ./script/build_saver.sh
```

Pushing a semantic version tag such as `v3.16.0` runs the GitHub Actions release
workflow. It builds and validates the screen saver, creates a GitHub Release,
and uploads the universal zip plus its SHA-256 checksum. The tag must exactly
match both `CFBundleShortVersionString` and `CFBundleVersion` in
`Resources/Info.plist`. The workflow can also be started manually to produce a
downloadable Actions artifact. Leave `publish_tag` empty for artifact-only mode,
or provide an existing semantic tag such as `v3.16.0` to create or update that
GitHub Release directly from the workflow.

Automated artifacts are ad-hoc signed for bundle integrity, but are not signed
with an Apple Developer ID or notarized. Developer ID signing and notarization
require certificate and App Store Connect credentials configured as repository
secrets.

## Install

Install for the current user by placing the built bundle at:

```text
~/Library/Screen Savers/
```

After replacing an installed copy, quit and reopen System Settings. The macOS
screen saver host caches `.saver` bundles aggressively, especially when testing
the same bundle identifier repeatedly.

## Settings

The native settings sheet supports:

- density
- speed
- encoding mode
- fog
- waves
- panning
- frame rate limit
- pause rendering when the current display sleeps
- FPS display
- debug overlay with per-display FPS state and process CPU/MEM usage

Settings UI strings are localized in English and Simplified Chinese.

## Reference Tools

`Tools/XScreensaverGLMatrix` contains a small AppKit/OpenGL harness used to
compare against the original xscreensaver GLMatrix algorithm.

`Tools/LegacyPreview` contains a host that loads a local legacy
`GLMatrix.saver` bundle directly for screenshot comparison. The legacy binary
is intentionally ignored by git; place it at the repository root as
`GLMatrix.saver` when using that tool.

## Notes

`dist/` and `.build/` are generated output and are not tracked. Rebuild the
screen saver with `./script/build_saver.sh`.

The frame rate setting controls the backing `MTKView` preferred frame rate.
Animation speed is advanced from elapsed time, so lower frame-rate limits do
not slow down the effect. Display sleep pausing is evaluated per screen, so
multi-display screen saver views stop independently when their own display is
asleep or unavailable. Dynamic glyph instances are prepared once for all active
displays on a shared utility-QoS ring. The producer refills from four to twelve
ready snapshots, and each display keeps three small uniform buffers for
independent Metal submission and presentation. Ring slots are reused only after
they fall behind the newest due snapshot and all GPU readers have completed;
slow displays skip stale snapshots instead of blocking the producer.
Metal views and renderers are created only after
an active screen saver view is attached to a window, then released from
`stopAnimation()` because the macOS legacy host can keep stopped view objects
alive for later reuse.

The debug overlay reports per-display FPS as seen by each screen saver view.
It also distinguishes submitted, GPU-completed, and actually presented frames,
and reports instance counts, drawable size, in-flight frames, Metal errors,
resource misses, actual/preferred GPU registry IDs, and live view/renderer
counts. CPU and memory are sampled once per interval for the current process,
so every display reports the same process-wide snapshot. CPU uses Activity
Monitor's convention where 100% equals one fully occupied logical core; the
overlay also shows the value normalized across all active logical cores.
Metal exposes the current
device allocation size through `MTLDevice.currentAllocatedSize`, so the overlay
shows that as `GMEM self`. Real-time global GPU utilization is not available
through a stable public Metal API, so it is displayed as `GPU global n/a`.
