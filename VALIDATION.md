# HiDPI 2.0 validation

Validated on September 14, 2026, on the local Apple Silicon Mac running macOS
27.0 (26A428).

## Passed

- `make test`: 65 assertions covering mode selection and refresh precision,
  individual display identities, duplicate serials, preferences, favorites,
  profile validation/serialization, preview/commit/revert ordering, failures,
  process locking, retry limits/cancellation, reversible cleanup, symlink
  exclusion, and display selector validation.
- CLI smoke tests: help, version, status, display listing, profile listing,
  dry-run cleanup, and rejection of invalid sizes/rates/options.
- `build/hidpi-preview-timer-test` in a GUI session: the real native modal
  countdown returned the revert decision after 1.05 seconds. This test does
  not configure displays; normal mode previews use 15 seconds.
- Visual and accessibility inspection of General, Profiles & Favorites, and
  Diagnostics; generated app icon renders correctly. Empty profile actions
  are disabled, profile naming opens, Cancel returns to settings, and Command-Q
  cleanly exits the preview.
- Native app initialization verified after adding explicit `finishLaunching()`.
- Live read-only mode discovery and diagnostics detected both ASUS monitors,
  using the SkyLight driver list: 118 modes for VG27A and 150 for ROG PG279Q.
- Both monitors remained at 1920 × 1080 HiDPI, rendering 3840 × 2160 at 144 Hz
  after validation.
- `codesign --verify --strict build/HiDPI.app` passed.
- ZIP integrity checked with `unzip -t build/HiDPI-2.0.zip`.

## Hardware actions not exercised

Actual resolution changes, hardware rollback, sleep/dock reconnect cycles,
login-item registration changes, and global hotkey registration were not
performed on the user's live setup. Their supporting logic is implemented,
and the automated checks above cover the testable behavior; these hardware
and OS integration paths still require hands-on acceptance testing.

Private SkyLight descriptor compatibility with other macOS releases, monitor
models, or connections is not established by this validation.

## Build outputs

- `build/HiDPI.app`: locally signed native application.
- `build/HiDPI-2.0.zip`: application archive, integrity verified.
- `build/hidpi`: standalone CLI.
- `Assets/HiDPI.png`: generated source icon.
- `build/HiDPI.icns`: packaged application icon.

Apple's `iconutil` needed execution outside the tool sandbox to assemble the
validated iconset; the same command succeeded with normal local access. The
build scripts use only system tools and the Swift toolchain.
