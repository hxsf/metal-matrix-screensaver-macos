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
- FPS display

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
