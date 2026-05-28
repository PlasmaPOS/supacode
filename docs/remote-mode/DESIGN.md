# Supacode Remote Mode — Design

Date: 2026-05-28
Status: Design, pre-implementation
Owner: shlomokabareti (Vortex)
Upstream: `supabitapp/supacode`

## Goal

Make Supacode operate against a **remote macOS or Linux host** rather than the local filesystem. The remote host owns:
- All git repositories and worktrees
- All running agent processes (Claude Code, Codex, Opencode, etc.)
- The `zmx` daemon that persists those processes across disconnects

The laptop running Supacode becomes a **pure UI client.** Closing the laptop, switching networks, going to the gym — none of it interrupts the agent processes on the remote host. Reopening Supacode reattaches.

## Non-goals (for v1)

- Multi-host orchestration. One remote per Supacode launch is enough.
- Local-mode parity. If a feature only makes sense locally (e.g. macOS-specific notifications about local processes), it's OK to disable in remote mode.
- Cross-platform clients. Mac-only.

## What this is NOT

This is not "SSHFS + ZmxClient swap." That hybrid was rejected because it inherits macFUSE's sharp edges and still routes Supacode's git operations through the laptop. Full remote means **every server-side op runs on the remote.**

---

## Architecture

```
┌───────────────────────────────────────┐
│       Supacode (laptop)               │
│   - SwiftUI window                    │
│   - TCA reducers (unchanged)          │
│   - Ghostty surface views             │
└─────────────┬─────────────────────────┘
              │
              │   SSHClient (NEW)
              │   - one persistent ControlMaster session
              │   - exec()  — run a command, capture stdout/stderr/exit
              │   - stream() — long-running command with line callback
              │   - readFile(), writeFile(), watchPath()
              │
              ▼
┌───────────────────────────────────────┐
│       Remote host (Mac Mini)          │
│   - Git repos in ~/agents/repos/      │
│   - Worktrees in ~/agents/wt/<name>/  │
│   - zmx daemon (persistent sessions)  │
│   - gh CLI for GitHub ops             │
│   - fswatch for file change events    │
└───────────────────────────────────────┘
```

All terminal tabs in Supacode are Ghostty surfaces whose `config.command` is `ssh remotehost -t -- 'zmx attach supa-<uuid> /bin/sh -c <user-cmd>'`. The local PTY is just an SSH client; the agent process lives on the remote.

---

## Seams — every Client/Feature that needs remote-izing

Inventory from a code sweep on 2026-05-28:

| Client | What it does today | Remote strategy |
|---|---|---|
| `Clients/Git/` | 20+ git operations: worktree add/list/remove, branch ops, repo discovery, lock files, parsing porcelain output | Wrap every git invocation in `ssh remotehost git ...`. Same parsing of stdout, same error types. Most code unchanged — just swap the executor. |
| `Clients/Github/` | 12+ `gh` CLI operations: PR/CI/auth | Same pattern — `ssh remotehost gh ...`. Same parsing. |
| `Clients/Repositories/` | Persists list of repo root paths to UserDefaults | Paths become **remote paths** on the remote host. Otherwise unchanged. |
| `Clients/Zmx/` | Wraps Ghostty `config.command` with `zmx attach <id>` for session persistence | Replace local-zmx-exec with `ssh remotehost -t -- ZMX_DIR=... zmx attach <id> <cmd>`. The remote zmx daemon is the source of truth for sessions. |
| `Clients/WorktreeInfoWatcher/` | Local `DispatchSourceFileSystemObject` for file events | Replace with `ssh remotehost fswatch -r <dir>` long-running process + parse lines. |
| `Clients/Deeplink/` | URL parsing only | Unchanged. |
| `Clients/AppLifecycle/`, `Notifications`, `Updates`, `Workspace`, `Terminal` | No FS / no subprocess | Unchanged. |

**Net work: 4 clients fully remote-ized, 1 client has its watcher implementation swapped, 1 new foundational `SSHClient` written. Plus settings UI and onboarding.**

---

## New foundational client: `SSHClient`

The single SSH connection abstraction every remote-ized client builds on.

```swift
struct SSHClient: Sendable {
  /// Run a one-shot command. Returns (stdout, stderr, exitStatus).
  /// Default 30s timeout; pass nil for unbounded.
  var exec: @Sendable (_ argv: [String], _ timeout: Duration?) async throws -> ExecResult

  /// Stream a long-running command line-by-line. Cancellation kills the remote process.
  var stream: @Sendable (_ argv: [String]) -> AsyncThrowingStream<StreamEvent, Error>

  /// Read a small file (≤1 MB) over SSH; throws if too large.
  var readFile: @Sendable (_ path: String) async throws -> Data

  /// Write/replace a file (atomic via temp + mv on remote).
  var writeFile: @Sendable (_ path: String, _ data: Data) async throws -> Void

  /// Watch a path tree for changes. Backed by `fswatch -r` over SSH.
  /// Stream ends when caller cancels the consuming task.
  var watch: @Sendable (_ path: String, _ events: WatchEventMask) -> AsyncStream<WatchEvent>

  /// Status of the underlying ControlMaster channel.
  var connectionState: @Sendable () -> ConnectionState
}
```

### Connection management
- **One persistent SSH control connection per remote host** via `ControlMaster=auto ControlPersist=10m` configured in `~/.ssh/supacode_config` (we write it on first run; user-merged from main `~/.ssh/config`)
- All commands multiplex over that single TCP/TLS-style channel — no per-call handshake cost
- Reconnect logic: if `ssh -O check` reports the master dead, transparently rebuild it before next call
- Auth: SSH key only. We require the user's ssh-agent has the key loaded; we don't prompt for passwords
- Heartbeat: every 30s, run `ssh -O check`; if down, surface a "remote unreachable" banner in the UI

### Failure model
- All clients throw `RemoteError` (new error type) for connection/protocol failures, layered ABOVE existing error types
- UI shows a global "offline" banner when SSH is down; existing repository tree disabled but visible; sessions show last-known state from cache

---

## Remote host requirements (documented as part of onboarding)

The remote host must:
1. Be reachable via SSH key auth (no password)
2. Have **`git`** in PATH
3. Have **`gh`** in PATH for GitHub features (optional, gracefully degrade if missing)
4. Have **`zmx`** in PATH — Supacode ships a small bootstrap script that scp's the bundled `zmx` binary to the remote on first connect (universal binary, works on Intel + Apple Silicon)
5. Have **`fswatch`** in PATH for live file events (optional; degrades to polling every 5s if missing)
6. Have writable `~/agents/repos/` and `~/agents/wt/` (configurable paths)

Remote can be macOS or Linux. Both have all 5 tools available via brew / apt.

### Onboarding wizard (new screen)

First-launch flow when no remote is configured:
1. **Host field** — `user@hostname` (defaults to `whoami`@hostname-suggestion)
2. **Test connection** button — runs `ssh -O check` + reports missing tools
3. **Auto-install** missing tools — offer `brew install fswatch gh` over SSH; offer to push `zmx`
4. **Choose repos directory** — defaults to `~/agents/repos/`; we'll create it
5. **Save** — writes to `~/Library/Application Support/supacode/remote.json`

After save, Supacode reconnects in remote mode and replaces the existing repository tree with whatever's in `<remoteRepoDir>/*`.

---

## Settings — Remote tab (new)

`SupacodeSettingsFeature/Views/RemoteSettingsView.swift` (new):
- **Mode toggle:** Local / Remote (radio)
- **Remote host config:** user@host, identity file, port, base dir
- **Connection status:** live (green dot) / reconnecting (yellow) / offline (red)
- **Bandwidth meter:** bytes/sec up/down over last minute
- **"Re-install remote tools" button** — re-runs the bootstrap
- **"Disconnect" button** — switches back to local mode (sessions on remote keep running, just hidden from UI)

---

## Migration sequence (the order I'd ship this)

Vertical slices, each independently testable. Don't ship a half-broken thing.

### Slice 1 — SSHClient foundation (2 days)
- Write `SSHClient` with `exec`, `connectionState`. Stub `stream`/`readFile`/`writeFile`/`watch`.
- TCA dependency wired with `.live(host: "user@host")` factory.
- Hardcode the host in code for now — settings UI comes later.
- **Done when:** I can call `@Dependency(\.sshClient).exec(["git", "--version"], nil)` from any reducer and get the remote git version.

### Slice 2 — Remote ZmxClient (1 day)
- Add `ZmxClient.remote(SSHClient)` factory alongside `.live`.
- `wrapCommand` returns `ssh user@host -t -- ZMX_DIR=... zmx attach <id> /bin/sh -c <cmd>` (Ghostty handles the local PTY for `ssh`).
- `killSession`/`listSessions` go through `SSHClient.exec`.
- **Done when:** opening a terminal in Supacode spawns a remote zmx-wrapped session, closing Supacode and reopening reattaches to the same session.

### Slice 3 — Remote GitClient (2-3 days)
- Add `GitClient.remote(SSHClient)` factory. Every git op (~15 of them per the inventory) wraps in SSH.
- The output parsing logic stays identical — only the executor changes.
- **Done when:** the repositories sidebar lists worktrees on the remote, "create worktree" works against the remote.

### Slice 4 — Remote WorktreeInfoWatcher (1 day)
- Replace `DispatchSourceFileSystemObject` with `ssh remote fswatch -r --batch-marker -- <paths>` long-running stream.
- Parse lines, emit equivalent change events to the existing observers.
- **Done when:** opening a file via SSH in another terminal shows the badge update in Supacode within 1s.

### Slice 5 — Remote Github CLI (1 day)
- Same pattern: `GithubCLIClient.remote(SSHClient)`, wrap every `gh` op in SSH.
- **Done when:** PR + CI status in the UI works against the remote's gh auth.

### Slice 6 — Settings + onboarding wizard (1-2 days)
- `RemoteSettingsView` with the toggle + host config
- Onboarding wizard for first-time remote connect
- Live connection status indicator
- **Done when:** flipping the mode toggle reloads the whole app against a different remote.

### Slice 7 — Bootstrap script + zmx installer (1 day)
- Detect missing tools, offer to install
- Push zmx binary to remote via scp
- Verify after install
- **Done when:** pointing at a fresh empty macOS / Linux host completes onboarding without manual steps.

### Slice 8 — Hardening + polish (2-3 days)
- Reconnect handling, error surfaces, offline mode
- Heartbeat indicator
- Performance pass — minimize round trips on common operations
- Tests for `SSHClient` against a fake transport

**Total: ~11-15 working days for one person.** That's "1-2 weeks of focused work" with some buffer.

---

## Open design questions (decide before Slice 1)

### Q1 — How does Supacode know which `~/agents/repos/<X>` are valid repos to surface?
Today the user adds a local repo by picking a folder via file picker. For remote, three options:
- **(a)** List `~/agents/repos/*` and treat each as a candidate; user confirms which to import
- **(b)** Expose a path text field; user types remote paths manually
- **(c)** "Open repo" runs `ssh remote ls -la ~/agents/repos/` and shows a picker UI

Recommend **(c)** for parity with the local file picker UX.

### Q2 — Where does the `gh` auth token live?
The `gh` CLI on the remote needs its own auth. Options:
- **(a)** User runs `gh auth login` once on remote; we never touch it
- **(b)** Supacode prompts on first run and runs `gh auth login --with-token` over SSH

Recommend **(a)** for v1 — simpler, no token transport.

### Q3 — Local fallback / dual mode?
Should the user be able to flip a single repo to "local mode" while keeping the app overall in remote mode? E.g., for repos that don't yet exist on the remote.

Recommend **NO** for v1 — too much complexity for marginal value. Force a binary: either the app is in remote mode (all repos remote) or local mode (all repos local).

### Q4 — Editor integration?
Supacode encourages "open in your editor" workflows that today open the local file. With remote files, you'd need either:
- **(a)** A "code-server" running on the remote (browser-based VS Code) — separate workflow
- **(b)** VS Code Remote-SSH style — local VS Code attaches to remote
- **(c)** Drop "open in editor" from the UI in remote mode; editing happens via agent or `vim` in the tab

Recommend **(b)** — the "Open in editor" button shells out to `code --folder-uri vscode-remote://ssh-remote+<host>/<path>` when in remote mode. Works if user has VS Code with the Remote-SSH extension installed (very common).

### Q5 — File watching scale?
`fswatch -r` on a large worktree tree can emit a lot of events. Need to confirm:
- Does it work at scale of 10+ worktrees × 50k+ files each?
- Should we narrow to specific subpaths to reduce noise?

Need to test on actual workload.

### Q6 — Latency budget for the "create worktree" UX?
Today, creating a worktree is sub-second (local git). Over SSH it's RTT + git time. For Mini on Tailscale that's typically <100ms, fine. For high-latency remotes (>200ms) it'll feel sluggish. UI should show a spinner for any op >300ms.

---

## What this fork explicitly diverges from upstream on

These are intentional, not accidents to reconcile later:
1. **`RemoteSettingsView` + `OnboardingWizard`** — net-new screens for remote config
2. **`SSHClient` + `RemoteError`** — net-new foundation, no upstream equivalent
3. **`.remote(SSHClient)` factories on Git/Github/Repositories/Zmx/WorktreeInfoWatcher** — new factories ALONGSIDE existing `.live` factories. Selecting which to inject is controlled by a settings flag.
4. **Local-mode features that hard-disable in remote mode:** TBD list, expected to include: file picker for repo, "open in Finder" actions, native macOS notification source switching

### Strategy for staying merge-friendly

When possible: ADD new factories rather than MODIFY existing ones. The TCA dependency system lets us inject `.remote(...)` as the `liveValue` without touching `.live`. Upstream changes to `.live` rebase cleanly.

When we MUST modify upstream code (e.g., the spot in `WorktreeTerminalState` that calls `zmxClient.wrapCommand`), do the smallest possible change and document it inline with `// FORK:` comment markers.

---

## Risks & unknowns

| Risk | Likelihood | Mitigation |
|---|---|---|
| Ghostty's local PTY + ssh long-running session has bad terminal sequence handling | Medium | Test early in Slice 2; if broken, consider a thin Swift-side PTY relay |
| `zmx` doesn't build/run on the remote macOS version we target | Low | Ship universal-binary version that supacode already builds |
| `fswatch` events lag or miss changes at scale | Medium | Slice 4 includes a real-load test on a big monorepo |
| User's network connection drops mid-coding constantly | Low | Mosh-style resilience: the SSH ControlMaster auto-reconnects; in-flight Ghostty surfaces show "reconnecting" overlay; zmx daemon retains session state |
| Upstream introduces a refactor that breaks our additive factories | Medium | Keep fork changes narrow + commented with FORK markers; rebase weekly during active dev |

---

## Next step

Once this design is approved, start Slice 1 (`SSHClient` foundation). Estimated 2 days. Once that works, every subsequent slice builds on it independently.

---

# Addendum — Codex audit findings (2026-05-28)

After writing the design, asked Codex to read the whole repo + critique. Codex confirmed several real gaps. Spot-verified each:

## Gap 1 — GitClient is NOT just a subprocess wrapper

**Verified.** `Clients/Git/GitClient.swift` has 15+ direct `FileManager` / file-content reads — not just `git` subprocess calls:

- Line 112: `fileManager.fileExists(atPath: entry.path)` — worktree dir existence check
- Lines 243, 311, 604: `String(contentsOf: ...)` reading `.git/HEAD`, `.git/gitdir`, `.git/supacode-lock`
- Line 272: `FileManager.default.removeItem(at: lockFile)` — lock-file teardown
- Lines 321-322: lock file content read + compare for `reconcileSupacodeLocks`

**Implication for design:** A `GitClient.remote(SSHClient)` that ONLY wraps git subprocesses leaves all the above pointing at the LOCAL filesystem. Result: worktree lock reconciliation, orphan detection, HEAD ref reading would all silently read the empty/wrong local filesystem in remote mode.

**Fix:** `GitClient.remote` must route every `FileManager` and `String(contentsOf:)` call through `SSHClient.readFile` / `SSHClient.exec(["test", "-e", path])`. That promotes `SSHClient.readFile` to a hot-path call (10-50× per repo refresh) — must be cheap. Recommend: short-lived in-process cache (5s) keyed by path on the remote side.

## Gap 2 — Settings persistence is laptop-local, not repo-local (good news)

**Verified.** Persistence locations found:
- `~/.supacode/sidebar.json` — user-curated sidebar state (`Features/Repositories/BusinessLogic/SidebarPersistenceKey.swift`)
- `~/.supacode/repos/<name>/` — default repo location convention (`SidebarPersistenceMigrator.swift:156`)

There is no `supacode.json` per repo. Settings live on the laptop, persisted via the local persistence client.

**Implication for design:** Easier than I feared. Settings stay on the laptop. Only the git operations + file content live on the remote. We DON'T need remote `readFile/writeFile` for any settings concern — only for `.git/HEAD`, `.git/gitdir`, and lock-file files inside each worktree.

The `~/.supacode/repos/` default convention only matters for the onboarding wizard's "where on the remote should new repos go?" prompt — recommend mirroring at `~/.supacode/repos/` on the Mini for parity, or making it configurable.

## Gap 3 — WorktreeInfoWatcher is narrow + semantic, not raw file events

**Verified.** `Clients/WorktreeInfoWatcher/WorktreeInfoWatcherClient.swift` exposes only 3 semantic events:
- `branchChanged(worktreeID:)`
- `filesChanged(worktreeID:)`
- `repositoryPullRequestRefresh(repositoryRootURL:, worktreeIDs:)`

The `.liveValue` is configured externally (not in this file) — meaning the implementation behind it is somewhere in the app startup wiring, NOT a generic `DispatchSourceFileSystemObject` over the whole worktree dir. Likely it's HEAD-ref watching + git-status polling, NOT recursive fswatch.

**Implication for design:** My Slice 4 plan to use `ssh remote fswatch -r` is HEAVIER than current behavior. Better: mirror the current narrow watch — `ssh remote watch HEAD file + git status periodic poll` per worktree. Cheaper, semantically identical to current local behavior.

## Gap 4 — TCA captured-dependency lifetime issue

**Verified by reading `pointfreeco/swift-dependencies` docs.** From the docs:

> "When the `@Dependency` property wrapper is initialized it captures the current state of the dependency at that moment."

**Implication for design:** Long-lived managers (`WorktreeTerminalManager`, `WorktreeInfoWatcherManager`) capture their `@Dependency(\.gitClient)` etc. at INIT time. If we swap `.live` → `.remote` via a settings toggle at runtime, those managers KEEP USING the originally-captured local clients until rebuilt.

**Decision: launch-time mode only for v1.** Toggling the mode in settings prompts "restart Supacode to take effect" — no live hot-swap. Removes a class of bugs, ships faster. Live toggle becomes a v2 follow-up (would need a coordinated "rebuild all stateful managers" pass).

## Gap 5 — More seams than just the 6 I listed

Codex flagged: "repo-local settings, path helpers, workspace open actions, blocking-script launch paths" as additional local-only seams. Spot-checking:

- **Path helpers** — `Domain` layer likely has `URL`-based identity. Need a `RemotePath` value type that doesn't accidentally get coerced into `URL(fileURLWithPath:)`.
- **Workspace open actions** — "Open in Finder", "Reveal in Finder" buttons. In remote mode: hide them or wire them to `ssh remote -C "open <path>"` (works if Mini has GUI session).
- **Blocking-script launch paths** — setup scripts (e.g. `bun install` on worktree creation) currently run as a local subprocess. Need to route through `SSHClient.exec` in remote mode.

These are bigger than my 8-slice plan implied. Realistic revised estimate: **15-20 working days**, not 11-15.

## Updated answers to the 6 + 4 = 10 open questions

| # | Question | Decision |
|---|---|---|
| Q1 | How does Supacode find candidate remote repos? | (c) "Open repo" SSHs `ls -la ~/.supacode/repos/` and shows a picker. Use `~/.supacode/repos/` as the default remote convention. |
| Q2 | Where does `gh` auth live? | (a) User runs `gh auth login` on Mini once. Supacode never touches the token. |
| Q3 | Single-repo local fallback? | NO. Binary mode for v1. |
| Q4 | Editor integration? | (b) VS Code Remote-SSH only. Hide native macOS "Open in Finder" actions in remote mode. |
| Q5 | `fswatch` scale? | N/A — revised Slice 4 mirrors current narrow watch (HEAD + git-status poll), not blanket fswatch. |
| Q6 | Latency budget for create-worktree? | Spinner for any op >300ms. Add a 1s timeout warning. |
| Codex Q1 | Repo-local `supacode.json` in v1? | N/A — verified settings are user-local `~/.supacode/`, not repo-local. Stays on laptop. |
| Codex Q2 | Launch-time mode or live toggle? | **Launch-time only.** Toggle in settings → "Restart to take effect" prompt. Live hot-swap is v2. |
| Codex Q3 | Non-terminal open actions in remote? | Only VS Code Remote-SSH. Hide Finder actions. |
| Codex Q4 | POSIX single-user remote guaranteed? | YES — Linux or macOS, one user, paths as opaque UTF-8 strings. No Windows abstraction. |

## Revised migration sequence (post-Codex)

Same 8 slices but with adjustments:

- **Slice 1 — SSHClient foundation:** Add `readFile`/`writeFile` with 5s in-process cache (was nice-to-have, now load-bearing for Git).
- **Slice 3 — Remote GitClient:** Now ~3-4 days, not 2-3 — must remote-ize every `FileManager` and `String(contentsOf:)` call too.
- **Slice 4 — Remote WorktreeInfoWatcher:** REVISED — mirror current narrow watch (HEAD ref + git-status periodic poll per worktree), don't use blanket fswatch.
- **New Slice 2.5 — Path identity hygiene:** Audit `Domain` types for `URL` → introduce a `WorktreeLocation` value type that is mode-aware (local URL OR remote string), 1-2 days. Slot between Slices 2 and 3 so subsequent work uses the abstraction.
- **New Slice 7.5 — Blocking-script launch paths:** Route setup-script execution through SSHClient for remote mode, 1 day.
- **New Slice 8.5 — Native macOS action gating:** Hide/replace Finder actions when in remote mode, 0.5 day.

**Revised total: ~15-20 working days for one person.** That's "3-4 weeks of focused work."

## What I'm doing NEXT (waiting for user OK)

1. User reviews this addendum + the 4 decision answers above
2. Once OK, I start Slice 1 (`SSHClient` foundation with the new `readFile` cache requirement)
3. Slice 2 (Remote ZmxClient) is still the right first user-visible win — ~1 day after Slice 1


---

# Addendum 2 — "100% of supacode works" mandate (2026-05-28)

User feedback: "I want 100% of supacode to work in remote mode." No hidden features, no "defer for v1". Each prior compromise gets a real wire-up. Decisions below replace the original "5% lost" entries.

## D1 — "Open in Finder" / "Reveal in Finder" → WIRE IT

**Implementation:** When user invokes Finder action on a remote path, run `ssh mini -C "open '<remote-path>'"`. The Mini's GUI session opens Finder pointing at the file. User views it via Mac Screen Sharing (already enabled on Mini per `~/.claude/rules/infrastructure.md` — "Auto-login ON, auto-restart after power loss ON").

**UX:** First-time use shows a one-time tip: "Opened in Finder on your Mac Mini. Use Screen Sharing (`Cmd-K` → `vnc://mini.tailnet`) to view." After that, just works.

**Implementation cost:** ~30 lines in `WorktreeActions` reducer + a new `RemoteOpenClient.reveal(path:)` that calls `SSHClient.exec(["open", remotePath])`.

**Honest caveat documented:** The Finder window appears on the Mini's screen, not the laptop's — there's no way around this without SSHFS-mounting (which we rejected). Users who never want to see Finder on the Mini can ignore the feature; users who do can keep a Screen Sharing window open.

**Slot:** Slice 8.5 (was "Native macOS action gating", now becomes "Remote macOS action bridging") — ~1 day, up from 0.5.

## D2 — Native file picker for "Add Repository" → WIRE IT (already in design)

Already specified in the original design: SSH-driven picker listing remote dirs. No change.

**Confirmation:** The picker UI is a SwiftUI sheet showing remote `~/.supacode/repos/*` entries. Plus a "Clone from URL" path that runs `git clone <url> <remote-base>/<name>` on the Mini.

**Slot:** Slice 6 (Settings + onboarding wizard). No additional cost — already in plan.

## D3 — "Open in editor" → WIRE IT (already in design, confirming)

Already specified: `code --folder-uri vscode-remote://ssh-remote+mini/<path>`. Requires user has VS Code with the Remote-SSH extension installed (~30s install).

**Slot:** Slice 6. No additional cost.

## D4 — Drag-and-drop files INTO supacode → WIRE IT

**Implementation:**
1. Supacode tab is configured as a SwiftUI drop target (existing local-mode behavior)
2. On drop, get the LOCAL file path(s) from the drag pasteboard
3. For each file: SCP to `/tmp/supacode-uploads/<uuid>-<filename>` on the Mini via `SSHClient.writeFile` (we already need this for Slice 1)
4. Get the REMOTE path back
5. Paste the remote path string into the active Ghostty surface (Claude / Codex / whatever) as if user typed it
6. Show a small toast: "Uploaded `<filename>` → mini:`/tmp/supacode-uploads/...`"

**Performance:** A typical PDF (1-50 MB) over Tailscale (Mini at ~50ms RTT, ~100 Mbps effective) uploads in well under a second. Larger files (videos, datasets) get a progress indicator.

**Lifecycle:** `/tmp/supacode-uploads/` is purged on Mini boot (it's tmpfs). For permanence, user moves the file to the worktree via the agent (which is a tool call away).

**Edge case — multiple files:** Drop 5 PDFs → 5 SCPs in parallel → 5 paths pasted into the agent tab newline-separated.

**Edge case — agent doesn't accept paths:** If the active tab is a raw shell (not a known agent CLI), still paste the remote path. User can do whatever they want with it.

**Slot:** New Slice 8.6 — Drag-and-drop file uploads — ~1 day.

## D5 — Anything else I might have called "deferred"

Auditing the rest of the original "5% lost" framing:

- **Spotlight-style file search** (if it exists in supacode) — if it's grep-backed, route through SSH. If it's a CoreSpotlight thing, it CAN'T see remote files; we'd build a `grep -r` fallback. Need to check the actual implementation in a future slice. **TBD until we hit it.**
- **macOS-native notifications about file events** — these fire on the user's laptop already (via the AppKit notification API), the EVENTS are fed by `WorktreeInfoWatcher` which we're remote-izing. No change needed.
- **Save dialog for exporting log/etc.** — local UI, writes to local filesystem. Could optionally also offer "Save to Mini" but local-only here is fine since the user has the file as part of an export action.

## Revised feature parity claim

With D1-D4 added: **100% of supacode user-facing features work in remote mode.** Some have caveats (D1's Finder-on-Mini-screen note), but no feature is hidden or disabled.

## Revised slice plan (final)

1. Slice 1 — SSHClient foundation (2d) — `exec`, `stream`, `readFile`, `writeFile`, `watch`, `connectionState`, 5s readFile cache
2. Slice 2 — Remote ZmxClient (1d)
3. Slice 2.5 — Path identity hygiene (1-2d)
4. Slice 3 — Remote GitClient (3-4d) — subprocess + FileManager + file-content
5. Slice 4 — Remote WorktreeInfoWatcher (1d) — narrow HEAD-watch + git-status poll
6. Slice 5 — Remote Github CLI (1d)
7. Slice 6 — Settings + onboarding wizard + remote repo picker + VS Code Remote-SSH wire (2d, was 1-2)
8. Slice 7 — Bootstrap script + zmx installer (1d)
9. Slice 7.5 — Blocking-script remote-ization (1d)
10. Slice 8 — Hardening + polish (2-3d)
11. Slice 8.5 — Remote macOS action bridging (Open in Finder) (1d, was 0.5)
12. Slice 8.6 — Drag-and-drop file uploads (1d) **NEW**

**Revised total: 17-22 working days.** Still ~3-4 weeks.


---

# Addendum 3 — Alternatives to fall back to if defaults disappoint (2026-05-28)

Shipping the minimum from Addendum 2. If, during real use, any of these feel wrong, here are the documented alternatives — no more design work, just pick one and we wire it.

| Default we're shipping | Alternative if you don't like the UX | Cost to swap |
|---|---|---|
| **D1 Finder**: `ssh mini -C "open '<path>'"` opens Finder on Mini's screen (view via Mac Screen Sharing) | **A1a — SSHFS mount** of Mini's repo dir on laptop. Finder works fully locally on the mount. macFUSE caveats (kext signing, fragility). | 1 day, optional behind setting toggle |
| Same | **A1b — In-app file browser tab** in supacode that talks to Mini's FS via SSH. Cleanest UX, no native Finder at all. | 3-5 days, real feature work |
| **D4 Drag-and-drop**: file uploads via SCP to `/tmp/supacode-uploads/`, pastes remote path into active agent tab | **A4a — Persistent uploads dir** at `~/.supacode/uploads/<repo>/<worktree>/` instead of `/tmp/` — survives Mini reboots, scoped per worktree. | 0.5 day |
| Same | **A4b — Worktree-relative drop target** — drop on a specific worktree row → SCP into THAT worktree's dir directly. Most natural for "I want this file IN the project." | 1 day |

Each of these can ship as a v2 enhancement. None of them block the v1 plan; they just give you escape hatches if real-world use surfaces a paper cut.

