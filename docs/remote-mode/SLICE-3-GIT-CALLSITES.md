# Slice 3 — GitClient remote-ization checklist

Inventory of every place in `Clients/Git/GitClient.swift` that currently does a LOCAL filesystem probe or process spawn. Each must be routed through `SSHClient` for remote mode.

## Decision: keep `URL` as the path-carrier type, audit the probes instead

The Codex audit warned about treating remote paths as local URLs. Verified the alternative — introducing a `WorktreeLocation` enum to replace `URL` in `Domain/Worktree.swift` + `Domain/Repository.swift` — ripples to every reducer, view, and reducer test in the app. Too big for v1.

**Lean answer: `URL` stays.** It becomes an opaque string-carrying value in remote mode. Nothing about `URL` requires a local filesystem to exist at that path; the `.fileURL` flag is just a hint to `Foundation`. The risk is only that *FS probes* (`FileManager.fileExists`, `String(contentsOf:)`, etc.) silently lie when handed a remote URL. So Slice 3's real surgery is: **every FS probe in GitClient becomes either an SSHClient call or a no-op.**

## File-by-file audit of `supacode/Clients/Git/GitClient.swift`

### Local-FS probes that MUST become SSHClient calls

| Line | Today | Slice 3 replacement |
|---|---|---|
| 106-112 | `FileManager.fileExists(atPath: entry.path)` — checks if a listed worktree dir actually exists locally | `try await sshClient.exec(["test", "-e", entry.path], .seconds(5)).succeeded` |
| 162-165 | `fileManager.fileExists(at: someURL)` — repo-root validation | Same pattern: `ssh test -e` |
| 213-215 | `fileManager.fileExists(at: someURL)` | Same |
| 238-243 | `FileManager.default.fileExists(atPath: path)` + `String(contentsOf: gitPointer)` — reads the `.git` pointer file from a worktree | `sshClient.readFile(path: gitPointerPath, bypassCache: false)` + parse |
| 266-272 | `FileManager.default.fileExists(atPath: path)` + `String(contentsOf: lockFile)` + `FileManager.default.removeItem(at: lockFile)` — supacode lock reconciliation | `sshClient.readFile(...)` + `sshClient.exec(["rm", "-f", lockPath], ...)` |
| 311 | `String(contentsOf: gitdirFile)` | `sshClient.readFile(path: gitdirPath, ...)` then decode UTF-8 |
| 321-322 | `FileManager.default.fileExists` + `String(contentsOf: lockFile)` | Same pattern |
| 604 | `String(contentsOf: headURL)` reading HEAD ref | `sshClient.readFile(path: headPath, ...)` |

### Local subprocess spawns (the bulk — these all become `ssh git ...`)

The `git` subprocess invocations (worktree add/list/remove, branch ops, fetch, etc.) are easier than the FS probes — they're argv-based. Each one becomes:

```swift
// before
try runGit(args: ["worktree", "list", "--porcelain"], cwd: repoURL)

// after (in .remote factory)
let result = try await sshClient.exec(
  ["sh", "-c", "cd \(shellQuote(repoURL.path)) && git \(args.joined(separator: " "))"],
  .seconds(30)
)
```

Or more cleanly, expose a `git` helper on the remote client:

```swift
private func git(_ args: [String], in repoURL: URL, timeout: Duration = .seconds(30)) async throws -> SSHClient.ExecResult {
  let cdAndGit = "cd \(shellQuote(repoURL.path)) && git \(args.map(shellQuote).joined(separator: " "))"
  return try await sshClient.exec(["sh", "-c", cdAndGit], timeout)
}
```

Specific subprocess sites in `GitClient.swift`:
- Line 95 — `git rev-parse --show-toplevel` (repo root resolution)
- Line 110 — `git worktree list --porcelain` (worktree discovery)
- Line 199-253 — multiple git calls for worktree creation
- Line 497 — `env`-prefixed git for clean environment
- Line 524 — porcelain output parsing of a different command
- Line 762 — another `env`-prefixed git

### Path-handling code that's UTC-safe (no change)

These currently use `URL(fileURLWithPath:)` but only to manipulate strings — no FS probe. They're safe to keep as-is when wired with remote-source paths:

- Line 95 — `URL(fileURLWithPath: trimmed).standardizedFileURL` — `.standardizedFileURL` does collapse `./` and `..` but does NOT touch the filesystem. Safe.
- Line 110 — same pattern.
- Line 253 — same.
- Line 317 — same.
- Line 524 — same.

### Things that are LOCAL-ONLY by design — keep them local

- Line 497, 762 — `URL(fileURLWithPath: "/usr/bin/env")` — this is the local executable for spawning local git. In remote mode we don't use this code path at all (we use `ssh`).

## The remote git helper that Slice 3 will introduce

```swift
extension GitClient {
  nonisolated static func remote(sshClient: SSHClient) -> GitClient {
    let executor = RemoteGitExecutor(sshClient: sshClient)
    return GitClient(
      repoRoot: { url in try await executor.repoRoot(at: url) },
      isGitRepository: { url in await executor.isGitRepository(at: url) },
      rootDirectoryExists: { url in await executor.directoryExists(at: url) },
      worktrees: { url in try await executor.worktrees(in: url) },
      reconcileSupacodeLocks: { url in await executor.reconcileSupacodeLocks(in: url) },
      // ... all 15+ closures, each delegating to executor methods
    )
  }
}

private struct RemoteGitExecutor: Sendable {
  let sshClient: SSHClient

  func git(_ args: [String], in dir: URL?, timeout: Duration = .seconds(30)) async throws -> SSHClient.ExecResult {
    let cd = dir.map { "cd \(shellQuote($0.path)) && " } ?? ""
    return try await sshClient.exec(
      ["sh", "-c", "\(cd)git \(args.map(shellQuote).joined(separator: " "))"],
      timeout
    )
  }

  func readFile(_ path: String) async throws -> String {
    let data = try await sshClient.readFile(path, false)
    guard let s = String(data: data, encoding: .utf8) else {
      throw RemoteError.remoteCommandFailed(exitCode: 0, stderr: "Non-UTF-8 in \(path)")
    }
    return s
  }

  func fileExists(_ path: String) async -> Bool {
    let r = try? await sshClient.exec(["test", "-e", path], .seconds(5))
    return r?.succeeded ?? false
  }

  // ... methods for each GitClient closure
}
```

## Expected line count delta for Slice 3

- `GitClient+Remote.swift`: ~400 lines (mirrors most of `GitClient.swift`'s logic but with remote executors)
- `RemoteGitExecutorTests.swift`: ~200 lines of unit tests using a fake `SSHClient`
- Modifications to existing files: 0 (additive factory pattern preserved)

## Performance check

GitClient calls (per typical sidebar refresh):
- `worktrees(at: repoURL)` — 1 ssh exec
- For each worktree: `fileExists` × 1, `readFile(HEAD)` × 1, sometimes `readFile(.git)` + `readFile(gitdir)` × 1, `git status --short` × 1
- → ~4-5 ssh calls per worktree × 5 worktrees per repo = ~20-25 calls per refresh
- With ControlMaster reuse: ~5ms each over Tailscale-local Mini = ~150ms total
- With the `readFile` 5s cache: most subsequent refreshes within 5s drop to ~10ms total

Feels native. If it doesn't, the right escalation is a single "git sidebar refresh" RPC that batches all the reads into one ssh call — defer until measured.
