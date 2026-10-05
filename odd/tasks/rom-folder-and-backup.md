# Feature: ROM folder selector + game backup (export)

## Objective
Let the user configure where their ROMs live (instead of scanning the whole
machine) and let them pull an already-installed game from the Switch to the Mac.

## Problem
- `availableFiles` is always empty: nothing ever scans a local folder, so the
  queue can never be populated from disk.
- No way to copy a game off the Switch.

## Why
User already has a ROM library at a known path and an installed game they want
backed up. Ad-hoc machine searches are not a substitute for a configured folder.

## Scope
1. Settings: pick and persist a ROM folder and a backup folder.
2. Recursive scan of the ROM folder -> `availableFiles`, with title-id/version
   parsed from the filename.
3. USB receive mode for Sphaira `CMD_EXPORT` -> write into the backup folder.

## Out of scope
- Decompression / re-compression (NSZ <-> NSP).
- Uploading files to the Switch (Sphaira has no PC->Switch upload path).
- Cloud or network transfer.

## Constraints
- Code, comments and log strings in English. No emoji.
- UI copy follows the existing app language (Spanish): existing views use
  "Explorar", "Instalados", "Cola de instalacion". New UI strings match that.
- Keep the existing Sphaira install (pull) path working unchanged.
- Export paths arrive from the Switch: sanitise them so the resolved file
  always stays inside the configured backup folder.

## Protocol facts (verified against /tmp/sphaira-proto)
- `SendDataPacket.Build(off,size,crc)` -> arg2=off>>32, arg3=off&0xFFFFFFFF,
  arg4=size, arg5=crc32c; packet CRC covers first 20 bytes.
- Export is initiated by the Switch: game menu -> "Export NSP"/"Export NSZ".
  Switch sends `SendPacket(CMD_EXPORT=1, path_len)` then the raw path, then
  streams `SendDataPacket` + raw payload, terminated by `SendDataPacket(0,0,0)`.
- Ack order per chunk: read packet -> send ResultPacket(OK) -> read payload ->
  verify crc32c -> send ResultPacket(OK|ERROR).
- Mode dispatch on the FIRST packet of a session:
  arg2 == 0 -> install (Sphaira handshake, table already sent by Mac);
  arg2 == 1 -> export, arg3 = path length.
  (Both use value 1 later for CMD_OPEN vs CMD_EXPORT, so the mode must be
  latched when the session opens.)
- Export path from the Switch contains subfolders -> parent dirs must be
  created before writing.

## Tasks

- [x] T1 `rom-folder-scan` — Persist `romFolder` with `UserDefaults`
      (not `@AppStorage`: the owner is `USBManager`, an `ObservableObject`,
      not a `View`), add a recursive scanner that filters .nsp/.xci/.nsz/.xcz
      and derives title id (`[010070201D1BA000]`) and version (`[v589824]`)
      from filenames, then fills `availableFiles`.
      Checks: `xcodebuild build` succeeds; scanner unit-logic exercised on the
      known folder `/Volumes/win/Consolas/Nintendo Swich Rooms`.

- [x] T2 `settings-ui` — Add `SettingsView` with folder pickers
      (`.fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:)`
      with `[.folder]` — there is no `isDirectory:` parameter) for ROM and
      backup folders, wire a sidebar entry, and show the active ROM folder +
      a Rescan action in `FileBrowserView`.
      Checks: build succeeds; folder persists across launches.

- [x] T3 `export-receive` — Latch session mode on the first packet; implement
      the export receive loop (ack order above, crc32c verify, parent-dir
      creation, `seek(off)` writes) into the backup folder; report progress.
      Checks: build succeeds; install path still works (regression).

- [x] T4 `verify` — xcodegen regenerate, full build, launch, and confirm the
      install regression plus export path in `/tmp/sendo.log`.
      Orchestrator independently re-ran the build -> `** BUILD SUCCEEDED **`.
      `/tmp/sendo.log` shows `arg2=0` -> `INSTALL mode` -> `session closed
      cleanly`. Git initialised at the project root, baseline `6f30588`.

- [ ] T5 `export-safety-fix` — the independent verifier FAILED the containment
      acceptance criterion and the end-to-end usability of the backup feature.
      Fix before delivery:
      - **C1** `SphairaClient.swift:275` — `standardizedFileURL` resolves `.`/
        `..` lexically but never symlinks, so an intermediate symlink inside
        the backup root redirects a write outside it (the prefix guard still
        passes). Resolve parent and root with `resolvingSymlinksInPath()` and
        open the leaf `O_NOFOLLOW`.
      - **C2** `SphairaClient.swift:233` — `removeItem` is a RECURSIVE delete
        and `fileExists` is true for directories, so a Switch path naming an
        existing folder inside the backup root wipes that subtree; the guard at
        `:277` also accepts `path == rootPath`, i.e. the whole backup folder.
        Reject the root itself; `lstat` and unlink only when `S_ISREG`.
      - **W1** session lifecycle — after `CMD_QUIT` or the 15 s idle timeout no
        session restarts, so a later dump hangs the Switch; and a live INSTALL
        session reads the dump header (`arg2=1`) as `CMD_OPEN` and loops ERROR.
        Restart serving while connected; do not raise the disconnect alert on
        the idle timeout or the restart loops.
      - **W2** `SphairaClient.swift:212,313` — `readExact` takes a raw
        `UInt32` (up to 4 GiB zero-filled). Bound `pathLength` and chunk size.
      - **W3** an export aborted by CRC mismatch still ends in
        `finishServing(success: true)` -> a truncated `.nsp` looks complete.
        Track an error flag per file and surface "La exportacion se
        interrumpio".
      - **W4** rejected-path retry storm + unbounded `SenDoLog` (fsync per
        line, no size cap).
      - **W5** stale `finishServing` after reconnect can reset a live session;
        guard it with a session token.
      Checks: build succeeds; install regression still clean in
      `/tmp/sendo.log`.

## Route / delegation
- T1+T2+T3: delegated direct (writer trigger: 2+ non-trivial files) — done.
- T4: bounded verification action — done.
- T5: delegated direct (one fix writer), then independent re-verification.

## Delivery
- Version control was absent at the start of this feature; the orchestrator
  ran `git init` (user-approved) with `.gitignore` excluding `.build/`,
  `xcuserdata/`, `.DS_Store` and DerivedData. Baseline `6f30588` captures the
  whole project including this feature, so the native review has no diff for
  T1-T4; verification of this change is writer self-verification plus an
  independent read-only verifier. Future work is reviewable normally.
- The baseline commit deliberately includes `SenDo/Sources/`, a stale
  duplicate tree that is dead code. Removing it is a separate decision.

## Acceptance criteria
- User can pick their ROM folder once; the app lists the games in it; selected
  files enter the install queue.
- User can pick a backup folder once; when the Switch exports a game, the NSP
  lands in that folder with its subfolders intact and a CRC-verified payload.
- Existing install-over-USB behaviour is unchanged.

## Progress
- [x] Explored protocol (`usb_export.py`, `usb_dumper.cpp`, `usb_api.hpp`) and
      UI structure.
- [x] T1 .. T4
- [ ] T5 (independent verification found 2 CRITICAL + 5 WARNING) — fix applied
      by the writer on `fix/export-safety` (build green); independent
      re-verification still pending.

## Verification evidence

Build (2026-10-04, writer run, derived data wiped first):
- `xcodegen generate` -> OK; `xcodebuild -list` -> targets `SenDo`, schemes `SenDo`.
- `xcodebuild -project SenDo.xcodeproj -scheme SenDo -configuration Debug build`
  -> ** BUILD SUCCEEDED ** (exit 0), zero Swift warnings/errors.
- `grep -rn "NUTClient\|TODO\|FIXME" SenDo/SenDo/` -> clean.

T1 scanner exercised on `/Volumes/win/Consolas/Nintendo Swich Rooms`
(standalone harness compiling the real `ROMScanner.swift` + `Models.swift`):
- 7 `.nsp` found (recursive, incl. `Swich/Room/`), 0 skipped; the 3 extra
  `._*.nsp` AppleDouble files are correctly excluded by `.skipsHiddenFiles`
  (10 nsp on disk = 7 real + 3 resource forks).
- title id / version parsed: `0100e65002bb8000`/`v0`, `0100E65002BB8800`/`v917504`,
  `010082E012A84800`/`v589824`, `010070201D1BA800`/`v524288`; `""`/`nil` for names
  without brackets; `Game [010070201D1B].nsp` -> `""` (16 hex digits required).
- `.keys` and `.zip` siblings correctly excluded.

T2 launch + UI (real run, screenshot-verified):
- defaults seeded with the two folders, app relaunched -> `USBManager: init —
  romFolder=/Volumes/win/Consolas/Nintendo Swich Rooms, backupFolder=.../SenDo Backup`,
  `backup folder ready`, `ROM scan finished — 7 file(s)` => persists across launches.
- Window renders (no Metal crash this run). Sidebar shows
  `Archivos / Cola / General > Ajustes`; clicking `Explorar` routes to
  `FileBrowserView` (title `Archivos Disponibles`) showing the folder path,
  `Reescanear`, `Seleccionar todo` / `Deseleccionar` and 7 rows with
  NSP badge, size and version; clicking `Ajustes` routes to `SettingsView`
  (title `Ajustes`) with both folder rows and `Cambiar...` buttons.

T3 regression (real hardware — a Switch was connected during the run):
- Session opened with `arg2=0` -> latched INSTALL, string table (0 files) sent,
  Switch answered `CMD_QUIT` -> `session closed cleanly` ->
  `serve session ended cleanly (CMD_QUIT)`. Two sessions, both clean.
- Protocol self-tests PASS on launch: `MemoryLayout<SPHPacket>.size = 24`,
  `CRC32C("123456789") = 0xE3069283`, packet round-trip,
  `mode latch (install=0, export=1)`, `export SendDataPacket offset round-trip`.
- Export loop was not exercised end-to-end (needs the user to trigger
  "Export NSP" on the Switch); its ack order, CRC handling, `seek(off)` writes
  and path sanitisation were reviewed line-by-line against
  `/tmp/sphaira-proto/tools/usb_export.py`.

Deliberate deviations from the task text:
- `UserDefaults` instead of `@AppStorage` (owner is `USBManager`, not a View).
- `.fileImporter(isPresented:allowedContentTypes:)` with `[.folder]` (no
  `isDirectory:` parameter exists in that API).
- `ContentView` restored to `NavigationSplitView { SidebarView } detail: { DetailView }`;
  the previous `HStack` had no navigation container, so every sidebar
  `NavigationLink` was dead.
- `onDeviceDisconnected` no longer clears `availableFiles` (the list is
  disk-backed now) but does clear `backupActivity` / `backupBytes`.

## Independent verification (T4, read-only verifier, separate session)

Verdict: protocol conformance PASS, install regression PASS, ROMScanner clean,
**containment acceptance criterion FAIL**.

- **PASS** — export ack order matches `usb_export.py` byte-for-byte (header ack
  -> path read -> path ack -> chunk ack -> payload -> CRC32C -> OK|ERROR ->
  terminator ack); `SendDataPacket` offset split matches `usb_dumper.cpp:55`;
  mode latch matches `usb_installer.cpp:33` (0) vs `usb_dumper.cpp:38` (1);
  CRC32C over first 20 bytes correct; `CMD_QUIT` acked before return.
- **PASS** — `serveInstall`/`serveOpenFile`/`transferChunkLoop` logically
  unchanged; no install regression.
- **PASS** — scanner runs off-main with a generation guard; hidden/AppleDouble
  excluded; directories excluded; extensions case-insensitive; no symlink
  cycles (Foundation's enumerator does not traverse directory symlinks).
- **PASS** — all `@Published` mutated on main; `serveQueue` is serial so two
  sessions cannot overlap; `USBDevice` kept retained by the closure.
- **FAIL C1/C2** — see T5. Two reachable defects: symlink redirection out of
  the backup root, and a recursive delete reachable from a Switch-supplied path
  (including the backup root itself).
- **FAIL W1** — the backup feature cannot actually complete end-to-end today:
  no session restarts after `CMD_QUIT`/15 s timeout, and a live INSTALL session
  misreads the dump header as `CMD_OPEN`.

## T5 fix (writer, branch `fix/export-safety`)

Build after the fix: `xcodegen generate` + `xcodebuild -project SenDo.xcodeproj
-scheme SenDo -configuration Debug build` -> ** BUILD SUCCEEDED **, zero Swift
warnings; `grep -rn "NUTClient\|TODO\|FIXME" SenDo/SenDo/` clean.

- **C1 fixed** — containment uses `resolvingSymlinksInPath()` on the backup
  root and on the resolved parent, re-checked AFTER the parents are created (a
  missing component cannot fool it); a root normalising to `/`, `.`/`..`
  components, control bytes and any existing ancestor that is not a directory
  resolving back inside the root are rejected. The leaf opens
  `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW` and is re-checked with `fstat`.
- **C2 fixed** — no `removeItem`/`createFile` on the destination any more:
  `lstat` first, `unlink` only after `S_ISREG` held, so a Switch path naming a
  folder (or the backup root itself) is rejected, never deleted.
- **W1 fixed** — sessions restart while connected (`.completed`/`.idle`
  immediately, `.failed` after 1 s backoff); the 15 s first-packet timeout now
  throws `SphairaProtocolError.sessionIdle`, ending the session WITHOUT the
  "stopped responding" alert; the restart re-checks token and connection at
  fire time.
- **W2 fixed** — `pathLength` bounded to 4096 bytes, export chunk size to
  64 MiB; announced-but-rejected bytes are drained in 64 KiB chunks before
  `RESULT_ERROR`, because the dumper blocks waiting for the ack of the bytes
  already sent (dropping them would desynchronise the stream).
- **W3 fixed** — `receiveExportBody` returns an error flag (CRC mismatch,
  failed write, oversized chunk); a session that ends after an interrupted file
  throws `exportInterrupted` -> "La exportación se interrumpió...", never
  `.completed`.
- **W4 fixed** — `/tmp/sendo.log` capped at 4 MiB and rotated to
  `/tmp/sendo.log.1` under a lock; rejected export paths log the FIRST
  occurrence per key and count repeats silently (aggregate every 100); the
  per-partial-read line in `USBTransfer.readExact` is gone.
- **W5 fixed** — every session carries a `sessionToken`, bumped on start and on
  disconnect; `finishServing(token:outcome:)` ignores stale results; only the
  first failure of a run raises the alert.
- Extras: `InstallFileList` box so every handshake serves the CURRENT queue
  (sessions restart automatically now, and a snapshot taken minutes earlier
  would drop games queued meanwhile); completion/failure is applied only to
  rows the session actually latched (`onHandshake`), so a never-sent game is
  not reported as installed; install progress matches by full path instead of
  file name; `ROMScanner` version regex is case-insensitive (`[V589824]`).

Still needs the Switch: the end-to-end "Export NSP" run and the install
regression re-run on real hardware.

## Next step
Re-verify T5 independently (the fix itself is applied on `fix/export-safety`),
commit as a work unit, then have the user trigger "Export NSP" on the Switch
for the first real end-to-end backup.
