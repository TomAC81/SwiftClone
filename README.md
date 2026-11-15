# SwiftClone

A small native macOS backup utility: pick a source, pick a destination, get a
fast incremental copy that is safe to interrupt. Independent implementation on
public macOS APIs.

Status: **0.1 — engine, UI, history, scheduling and verification work; not yet
tested on real external hardware at scale.** See *Known limitations*.

## Build

Requirements: macOS 27, Swift 6 toolchain. Full Xcode is optional.

```bash
./build.sh --run        # build SwiftClone.app and launch it
./build.sh --install    # also copy it to ~/Applications
./test.sh               # run the unit tests
```

The bundle is produced in `~/Library/Caches/SwiftClone-build/SwiftClone.app`
(outside the project so cloud-sync attributes can't break code signing) and
is ad-hoc signed.

**Xcode:** open `Package.swift` — Xcode treats the package as a project, with
the `SwiftClone` scheme runnable and the tests in the Test navigator. For a
classic `.xcodeproj`, `project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen)
spec (`xcodegen` generates it); that spec is untested so far.

Two quirks apply only when building without Xcode, because the Command Line
Tools ship fewer compiler plugins:

- Use `./test.sh` rather than plain `swift test`. The Swift Testing macro
  plugin is found only intermittently unless its path is passed explicitly,
  which the script does. With Xcode installed, `swift test` is fine.
- Views use `ObservableObject` instead of `@State`.

The icon is drawn in code: `swift Tools/make-icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns` regenerates it.

## Architecture

Full write-up, including the copy-engine comparison (FileManager vs rsync vs
POSIX/`copyfile`): [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

- **SwiftCloneCore** (library, no UI): validation → scan → space check → copy
  → verify. Enumeration is `opendir`/`fstatat`; copying is `copyfile(3)` into
  a temp file followed by an atomic rename; the per-directory diff
  (`BackupPlanner`) is a pure function.
- **SwiftClone** (SwiftUI app): job list and editor, progress, deletion
  preview, history, settings, timer-based scheduler.
- **Persistence:** `~/Library/Application Support/SwiftClone/jobs.json` and
  `history.json`. Logs: `~/Library/Logs/SwiftClone/`, one file per run.
  [Samples/sample-job.json](Samples/sample-job.json) shows the job format.

## Safety model

- **Backup mode (default)** only adds and updates. It never deletes, and never
  replaces a folder with a file or vice versa.
- **Mirror mode** scans first and shows every item it would delete. Only the
  exact paths you confirm are removed; anything that appears later is left
  alone. "Back Up Without Deleting" is the default button.
- **Scheduled runs never delete**, even for mirror jobs — nobody is there to
  confirm.
- Refused outright: source = destination, either inside the other (checked by
  path and by device/inode, so symlinks can't hide it), missing or read-only
  destination. A missing destination is never created, so an unplugged drive
  can't turn into a folder on your startup disk.
- Free space is checked before anything is written.
- Files are written under a temporary name and renamed when complete. Cancel,
  crash or power loss leaves the previous version in place; re-running the job
  continues where it stopped.
- If the destination drive disappears mid-run, the run stops immediately.
- Every deletion and every error is logged.

## Permissions

- Not sandboxed, no privileged helper. It can copy whatever your user account
  can read.
- **Full Disk Access** (System Settings › Privacy & Security) is needed for
  protected locations such as Mail, Messages, Safari data, or Time Machine
  volumes. Settings has a button that opens the pane.
- macOS will ask once for access to Desktop/Documents/Downloads, removable
  and network volumes the first time a job touches them.

## Known limitations

- **Not a bootable clone.** It copies files; it does not replicate APFS volume
  groups or make a startup disk.
- **No APFS snapshots.** The source is read live; files that change during a
  run may be copied in an inconsistent state (verification flags them).
  Creating snapshots needs root or a restricted entitlement.
- **Schedules only fire while the app is open.** There is no background agent.
- **Files owned by other users / root-only files** are reported as errors, not
  copied. Ownership is preserved only where the current user is allowed to set it.
- **Hard links** are copied as separate files. Sockets, devices and FIFOs are skipped.
- **Case-sensitive source → case-insensitive destination:** two names
  differing only by case collide; the second overwrites the first.
- **Pause** takes effect between files; a large file in flight finishes first.
- **Mirror deletion of a folder** removes its whole contents as previewed; a
  file added inside that folder between preview and confirmation goes with it.
- No `fsync` per file: a power cut can lose the most recently copied files
  (never corrupting older ones). Re-run to repair.
- Restore is a simple "copy these items back" picker; the backup is a plain
  folder you can also browse in Finder.
- Not yet tested: physically unplugging a drive mid-run, multi-million-file
  trees, network volumes, Intel Macs. The logic for the first is covered by
  code paths and unit tests only up to "destination missing/changed".

## Tests

`./test.sh` covers path validation, change detection, backup planning,
mirror-mode deletion protection, the engine end-to-end on temporary folders
(incremental runs, cancel, leftover partial files, unreadable files, full
disk, checksum verification), scheduling, persistence and restore.
