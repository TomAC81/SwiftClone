# SwiftClone — Architecture

SwiftClone is an independent backup utility built only on public macOS APIs
(POSIX file calls, `copyfile(3)`, Foundation, SwiftUI). It shares no code,
assets, UI or terminology with any other product.

## Layout

```
Package.swift                 SwiftPM manifest (opens directly in Xcode)
Sources/SwiftCloneCore/       Engine library: no UI, fully unit-testable
  Models.swift                BackupJob, Schedule, RunRecord (all Codable)
  Persistence.swift           JSON job database + run history
  PathValidator.swift         Source/destination safety checks
  VolumeInfo.swift            statfs wrapper: filesystem type, free space
  Scanning.swift              Directory listing via opendir/fstatat
  ChangeDetector.swift        "Is this file unchanged?" rule
  BackupPlanner.swift         Pure per-directory diff -> actions
  FileCopier.swift            copyfile(3) to temp file + atomic rename
  AdaptiveConcurrency.swift   Hill-climbing limit for parallel copies
  BackupEngine.swift          Orchestration: scan, space check, copy, delete
  Verifier.swift              Metadata / SHA-256 verification
  RunControl.swift            Pause and cancel
  RunLogger.swift             Per-run log file
  ScheduleCalculator.swift    Next-run date maths
  SnapshotSupport.swift       APFS snapshot capability probe
  Restorer.swift              Copy items back out of a backup
Sources/SwiftClone/           SwiftUI app (thin layer over the core)
Tests/SwiftCloneCoreTests/    Swift Testing suites
Samples/sample-job.json       Example job configuration
```

## Copy engine: the three options

| | A. `FileManager.copyItem` | B. `rsync` subprocess | C. POSIX + `copyfile(3)` |
|---|---|---|---|
| Metadata (xattrs, ACLs, flags) | Yes | Apple's bundled rsync is old (2.6.9 lineage / openrsync); xattr and ACL handling varies by version | Yes, same code path Finder-level tools use |
| Byte-level progress | No | Only by parsing text output | Yes, progress callback |
| Cancel mid-file | No | Kill the process | Yes, callback returns `COPYFILE_QUIT` |
| Incremental logic | You write it anyway | Built in | You write it |
| Per-file error reporting | Good | Parse stderr | Good (errno per file) |
| Control over deletes | Full | `--delete` is one flag away from data loss; preview requires a separate dry run and output parsing | Full |
| APFS clones on same volume | Yes | No | Yes (`COPYFILE_CLONE`) |
| Dependencies / licensing | None | Behaviour differs across macOS releases; bundling a modern rsync means shipping GPLv3 code | None |
| Memory on huge trees | `enumerator` is fine; `contentsOfDirectory` URL arrays are heavy | Good | One directory in memory at a time |

**Choice: C.** Enumeration uses `opendir`/`readdir`/`fstatat` (one `stat` per
entry, no `URL` allocation), and each file is copied by `copyfile(3)`. That
gives byte progress, mid-file cancellation, full metadata and clone support,
with errors attributable to a single file. FileManager is used only where
none of that matters (restore, recursive removal). rsync is rejected because
its behaviour and output format are not stable across macOS versions and a
destructive flag is too easy to reach.

## How a run works

1. **Validate** paths (`PathValidator`). Refuses: missing source, missing
   destination (never creates a destination root — an unmounted
   `/Volumes/Backup` must not turn into a folder on the boot disk), identical
   paths, either path inside the other, read-only destination. Containment is
   checked twice: by path components and by device+inode while walking up
   parents, so symlinks and case differences cannot hide an overlap.
2. **Scan** (dry run of the same walk). Produces file/byte totals for
   progress and the list of deletion candidates. Nothing is written.
3. **Space check.** Bytes to copy (plus a small margin) must fit in the
   destination's free space, or the run fails before touching anything.
4. **Copy.** The tree is walked one directory at a time. For each directory
   the source and destination listings are diffed by `BackupPlanner` (a pure
   function), files to copy run in a bounded task group, then sub-directories
   are visited. Directory metadata is applied after its children.
5. **Verify** (optional): metadata comparison of every file, or SHA-256 of
   both sides.
6. **Record** the run in history and close the log.

### Change detection

A file is unchanged when type, size and modification time match. The mtime
comparison tolerance depends on the destination filesystem (0 for APFS, 1 s
for HFS+, 2 s for FAT/exFAT/network), because those filesystems round
timestamps.

### Interrupted runs

Every file is written to `.<name>.swiftclone-partial` and renamed over the
final name only after `copyfile` succeeds. A crash, cancel or unplugged drive
therefore never leaves a half-written file under a real name. Re-running the
job is the resume mechanism: finished files are skipped as unchanged, stale
partials are removed, and the rest is copied.

### Disconnected drives and full disks

The destination's device id is captured at start and re-checked at every
directory. If the root disappears or changes device, the run stops with a
"destination disconnected" failure. `ENOSPC` stops the run with "destination
full".

### Concurrency

Copies within a directory run in parallel with a limit chosen by
`AdaptiveConcurrency`: start at 2, measure throughput per window, add a
worker while throughput improves and back off when it drops. Range 1–8. This
lets SSDs use parallelism for small files while spinning or USB drives settle
at 1–2.

### Memory

Only the current directory's listings and the chain of parent frames are in
memory. The exception is the mirror-mode deletion list, which is kept in full
so it can be shown to the user and enforced exactly.

## Safety model

- **Backup mode** never deletes or replaces anything by type. Files only get
  added or updated.
- **Mirror mode** deletes only paths contained in a `DeletionApproval`, which
  the app builds from the preview the user just confirmed. Anything that
  appears in the destination after the preview is left alone. Without an
  approval (including every scheduled run) mirror behaves like backup and
  reports how many items were left in place.
- A destination item of a different type than the source (folder vs file) is
  treated as a deletion and needs the same approval.
- Every deletion is written to the run log.

## Snapshot layer

`SnapshotSupport` only reports whether the source volume is APFS. Creating
and mounting a snapshot needs either root or the restricted
`com.apple.developer.vfs.snapshot` entitlement, so it is deliberately kept
out of the file-sync path and not implemented yet. The engine works on the
live filesystem; files that change mid-run are caught by verification.

## Scheduler

`ScheduleCalculator` is pure date maths. The app holds one `Timer` aimed at
the soonest next run, and listens to `NSWorkspace.didMountNotification` to
start jobs that were missed or are set to run when their destination
appears. There is no helper process or launch agent: schedules fire only
while the app is open.

## macOS APIs and entitlements

| Need | API | Entitlement / permission |
|---|---|---|
| Enumerate, copy | POSIX, `copyfile(3)` | Full Disk Access for protected folders (Mail, Safari, other users) |
| Free space, fs type | `statfs` | none |
| Mount events | `NSWorkspace` notifications | none |
| Folder pickers | `NSOpenPanel` | none (non-sandboxed) |
| Checksums | CryptoKit | none |

The app is **not sandboxed**. A sandboxed build would need
`com.apple.security.files.user-selected.read-write` plus security-scoped
bookmarks stored with each job; the job model keeps plain paths today.
No privileged helper is used, so files the current user cannot read are
reported as errors rather than copied.

## Phases

1. Foundation — models, persistence, UI shell. **Done**
2. Engine — validation, scan, change detection, copy, cancel/pause. **Done**
3. History and logging. **Done**
4. Scheduling — daily/weekly, destination-appears. **Done (app must be open)**
5. Verification — metadata and checksum. **Done**
6. Hardening — covered by automated tests where possible; real-hardware
   tests (pulling a drive, multi-million-file trees) still to do.
