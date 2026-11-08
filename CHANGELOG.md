# HiDPI 2.1

- Release builds are universal (Apple Silicon and Intel) and run on macOS 13 or
  later; `make release` produces the app and CLI archives with checksums.

- Connecting a monitor now restores only that monitor; startup and wake still
  restore all monitors. Restore switches monitors in one shared configuration
  with a per-monitor fallback.
- Remember mode changes made in System Settings for monitors HiDPI restores, so
  wake/reconnect no longer undoes them (optional, on by default).
- Reverting a preview applies the previous modes for the session only, instead of
  writing them permanently.
- Quitting, logging out, or shutting down during a preview reverts it instead of
  cancelling the logout.
- One global shortcut conflict no longer disables all shortcuts; failures are named.
- `--no-restore` inspection sessions keep shortcuts off after settings changes.
- The private mode list must contain the current mode or the public list is used;
  fallback lists are now filtered, deduplicated, and sorted like the private list.
- `hidpi set` accepts the `1920 × 1080` form that `list` and `modes` print.

# HiDPI 2.0

- Added 15-second confirmed previews with automatic reversion, process-exit
  fallback, rollback on failure, and preferences saved only after confirmation.
- Stage multi-monitor changes in a shared CoreGraphics transaction and reject
  unavailable profile targets before applying anything.
- Identify monitors individually using system UUIDs, with serial and session
  fallbacks. Handle ambiguous old preferences conservatively.
- Added per-monitor menus, suggested scales, complete mode/refresh submenus,
  and explicit display diagnostics instead of the removed `enable` command.
- Added favorites and named profiles with save, apply, rename, update, and delete.
- Added opt-in global shortcuts for favorites and profiles.
- Added native settings, launch-at-login management, startup/wake restore toggles,
  pause, and forgetting saved settings.
- Added bounded reconnect retries, process locking, per-display restore results,
  and a copyable diagnostics report with actual mode sources.
- Made legacy override cleanup opt-in for foreign files and reversible through
  retained backups and an undo command.
- Fixed help/version without a display session and tightened CLI validation.
- Added generated application artwork, ICNS packaging, direct bundle startup,
  verified local signing, and explicit app initialization.
- Added automated regression tests, CLI smoke checks, and an optional native
  modal-timer integration check.
