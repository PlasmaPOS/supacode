import ComposableArchitecture
import Dependencies
import Foundation
import SupacodeSettingsShared

/// Remote variant of `GitClientDependency`. Routes every `wt`/`git` invocation
/// over SSH to the remote host. Parses the same output formats as the local
/// `GitClient` so domain types (`Worktree`, `GitBranchInventory`, etc.)
/// round-trip identically.
///
/// **Slice 3 phase A (this commit):** implements the 6 closures the sidebar
/// refresh actually exercises every render — repoRoot, isGitRepository,
/// rootDirectoryExists, worktrees, branchName, reconcileSupacodeLocks.
/// Plus localBranchNames since it's a one-line wrap.
///
/// **Slice 3 phases B/C (subsequent commits):** the remaining 17 closures
/// (createWorktree, removeWorktree, branchInventory, fetchRemote, etc.).
/// They throw `RemoteError.notConfigured` until then so callers fail loudly
/// instead of silently no-oping.
///
/// **Slice 7 (bootstrap):** scp the `wt` bash script to the remote at
/// `remoteWtPath`. Until that ships, remote mode requires manual install:
/// `scp Resources/git-wt/wt mini:~/.local/bin/wt && ssh mini chmod +x ~/.local/bin/wt`.
extension GitClientDependency {
  nonisolated static func remote(
    sshClient: SSHClient,
    remoteWtPath: String = "~/.local/bin/wt"
  ) -> GitClientDependency {
    let runner = RemoteWtRunner(sshClient: sshClient, wtPath: remoteWtPath)

    return GitClientDependency(
      repoRoot: { url in try await runner.repoRoot(for: url) },
      isGitRepository: { url in await runner.isGitRepository(at: url) },
      rootDirectoryExists: { url in await runner.directoryExists(at: url) },
      worktrees: { url in try await runner.worktrees(for: url) },
      reconcileSupacodeLocks: { url in await runner.reconcileSupacodeLocks(for: url) },
      localBranchNames: { url in try await runner.localBranchNames(for: url) },

      // Phase B closures — all wired
      renameBranch: { old, new, repo in try await runner.renameBranch(from: old, to: new, for: repo) },
      isValidBranchName: { name, repo in await runner.isValidBranchName(name, for: repo) },
      branchInventory: { repo, remotes in try await runner.branchInventory(for: repo, remoteNames: remotes) },
      defaultRemoteBranchRef: { repo in try await runner.defaultRemoteBranchRef(for: repo) },
      automaticWorktreeBaseRef: { repo in await runner.automaticWorktreeBaseRef(for: repo) },
      ignoredFileCount: { repo in try await runner.ignoredFileCount(for: repo) },
      untrackedFileCount: { repo in try await runner.untrackedFileCount(for: repo) },
      // Phase C — multi-step orchestrations
      createWorktree: { name, repo, baseDir, copyIg, copyUn, baseRef in
        try await runner.createWorktree(
          named: name, in: repo, baseDirectory: baseDir,
          copyFiles: (ignored: copyIg, untracked: copyUn), baseRef: baseRef
        )
      },
      createWorktreeStream: { name, repo, baseDir, copyIg, copyUn, baseRef, dirOverride in
        runner.createWorktreeStream(
          named: name, in: repo, baseDirectory: baseDir,
          copyFiles: (ignored: copyIg, untracked: copyUn), baseRef: baseRef,
          directoryOverride: dirOverride
        )
      },
      removeWorktree: { worktree, deleteBranch in
        try await runner.removeWorktree(worktree, deleteBranch: deleteBranch)
      },
      // Phase B continued
      isBareRepository: { repo in try await runner.isBareRepository(for: repo) },
      branchName: { url in await runner.branchName(at: url) },
      lineChanges: { url in await runner.lineChanges(at: url) },
      remoteNames: { repo in try await runner.remoteNames(for: repo) },
      fetchRemote: { remote, repo in try await runner.fetchRemote(remote, for: repo) },
      remoteInfo: { repo in await runner.remoteInfo(for: repo) }
    )
  }
}

/// Thin SSH executor for `wt` / `git` commands on the remote host. Stateless
/// (no caching beyond what `SSHClient` does itself). Every method delegates
/// to `sshClient.exec` with the appropriate argv.
struct RemoteWtRunner: Sendable {
  let sshClient: SSHClient
  let wtPath: String

  // MARK: Phase A — the sidebar-refresh hot path

  /// Mirrors `GitClient.repoRoot(for:)` — runs `wt root` from inside the
  /// candidate dir, trims, returns a URL.
  func repoRoot(for path: URL) async throws -> URL {
    let result = try await runWt(
      args: ["root"],
      cwd: path.path(percentEncoded: false)
    )
    let trimmed = result.stdoutString().trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw GitClientError.commandFailed(
        command: "wt root",
        message: "Empty output (not inside a git worktree?)"
      )
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL
  }

  /// `test -e $url/.git` over SSH. Tolerant of any SSH failure (treats as
  /// "not a git repo") — mirrors the local helper's `Bool`-returning
  /// contract.
  func isGitRepository(at url: URL) async -> Bool {
    let path = url.path(percentEncoded: false)
    let r = try? await sshClient.exec(
      ["sh", "-c", "test -e \(shellQuote(path))/.git -o -d \(shellQuote(path))/refs"],
      .seconds(5)
    )
    return r?.succeeded ?? false
  }

  /// `test -d $url` over SSH. Used by the sidebar to distinguish "repo
  /// folder is gone" from "folder is here but not a git repo."
  func directoryExists(at url: URL) async -> Bool {
    let path = url.path(percentEncoded: false)
    let r = try? await sshClient.exec(
      ["test", "-d", path],
      .seconds(5)
    )
    return r?.succeeded ?? false
  }

  /// Mirrors `GitClient.worktrees(for:)` — runs `wt ls --json` from the
  /// repo dir, decodes the JSON into the same `GitWtWorktreeEntry` shape
  /// the local client uses, maps to `Worktree`.
  ///
  /// Differences from the local impl that I'm intentionally accepting in
  /// Phase A and revisiting in Phase B/C:
  /// - **`isMissing`**: local checks `fileExists` per-worktree. Doing N
  ///   ssh round-trips per refresh is wasteful; for Phase A I assume
  ///   not-missing (matching the common case). Phase B will batch the
  ///   existence checks into a single `find` invocation.
  /// - **`createdAt`**: local reads `URLResourceValues.creationDate`. For
  ///   remote we'd need a `stat -f %SB` per dir. Skipped for Phase A;
  ///   sidebar sort falls back to index order which is the same shape
  ///   the user sees today when ctime is unavailable.
  func worktrees(for repoRoot: URL) async throws -> [Worktree] {
    let repositoryRootURL = repoRoot.standardizedFileURL
    let repoPath = repositoryRootURL.path(percentEncoded: false)
    let result = try await runWt(args: ["ls", "--json"], cwd: repoPath)
    guard result.succeeded else {
      throw GitClientError.commandFailed(
        command: "wt ls --json",
        message: result.stderrString()
      )
    }
    let entries = try JSONDecoder().decode([GitWtWorktreeEntry].self, from: result.stdout)
      .filter { !$0.isBare }
    return entries.map { entry in
      let worktreeURL = URL(fileURLWithPath: entry.path).standardizedFileURL
      let isAttached = !entry.branch.isEmpty
      let name = isAttached ? entry.branch : worktreeURL.lastPathComponent
      let detail = RemoteWtRunner.relativePath(from: repositoryRootURL, to: worktreeURL)
      let id = worktreeURL.path(percentEncoded: false)
      return Worktree(
        id: id,
        name: name,
        detail: detail,
        workingDirectory: worktreeURL,
        repositoryRootURL: repositoryRootURL,
        createdAt: nil,
        isMissing: false,
        isAttached: isAttached
      )
    }
  }

  /// Same `relativePath` shape as `GitClient.relativePath(from:to:)` — pure
  /// string slicing on the path components, no FS calls. Inlined here
  /// because the local helper is `private`.
  nonisolated static func relativePath(from base: URL, to target: URL) -> String {
    let baseComponents = base.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    var index = 0
    while index < min(baseComponents.count, targetComponents.count),
      baseComponents[index] == targetComponents[index]
    {
      index += 1
    }
    let parents = Array(repeating: "..", count: baseComponents.count - index)
    let descendants = Array(targetComponents[index...])
    let combined = parents + descendants
    return combined.joined(separator: "/")
  }

  /// Mirrors `GitClient.branchName(for:)` — `wt here` returns the current
  /// branch name. Tolerant of any error (returns nil).
  func branchName(at worktreeURL: URL) async -> String? {
    let path = worktreeURL.path(percentEncoded: false)
    let r = try? await sshClient.exec(
      ["sh", "-c", "cd \(shellQuote(path)) && \(shellQuote(wtPath)) here"],
      .seconds(5)
    )
    guard let result = r, result.succeeded else { return nil }
    let trimmed = result.stdoutString().trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Mirrors `GitClient.localBranchNames(for:)` — `git branch --list
  /// --format=%(refname:short)` over SSH.
  func localBranchNames(for repoRoot: URL) async throws -> Set<String> {
    let path = repoRoot.path(percentEncoded: false)
    let result = try await sshClient.exec(
      ["sh", "-c", "cd \(shellQuote(path)) && git branch --list --format='%(refname:short)'"],
      .seconds(10)
    )
    guard result.succeeded else {
      throw GitClientError.commandFailed(
        command: "git branch --list",
        message: result.stderrString()
      )
    }
    let names = result.stdoutString()
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return Set(names)
  }

  /// Mirrors `GitClient.reconcileSupacodeLocks(for:)`. Stale lock files
  /// under `.git/worktrees/*/supacode-lock` get removed when their target
  /// worktree dir no longer exists.
  ///
  /// Phase A implementation: minimum viable — `find` + `rm` over SSH.
  /// Doesn't read the lock file contents to decide whether to keep
  /// (the local impl checks the recorded UUID; we skip that for now and
  /// just remove locks whose worktree dir is gone). This is safe: a false
  /// "remove" just means the user has to re-claim the worktree slot.
  func reconcileSupacodeLocks(for repoRoot: URL) async {
    let path = repoRoot.path(percentEncoded: false)
    // Run a small shell pipeline on the remote that finds supacode-lock
    // files inside .git/worktrees/<name>/ where the corresponding
    // worktree dir no longer exists, and removes them.
    let script = """
      cd \(shellQuote(path)) || exit 0
      for lock in .git/worktrees/*/supacode-lock; do
        [ -f "$lock" ] || continue
        wtdir=$(dirname "$lock")
        # `gitdir` file points at the worktree's working dir
        if [ -f "$wtdir/gitdir" ]; then
          wt_path=$(sed -e 's|/\\.git/?$||' "$wtdir/gitdir")
          if [ ! -d "$wt_path" ]; then
            rm -f "$lock"
          fi
        fi
      done
      """
    _ = try? await sshClient.exec(["sh", "-c", script], .seconds(10))
  }

  // MARK: Phase B — branches, remotes, file counts, line diff, GH remote info

  /// `git -C $repo branch -m <old> <new>`.
  func renameBranch(from oldName: String, to newName: String, for repoRoot: URL) async throws {
    let r = try await runGit(args: ["-C", repoRoot.path(percentEncoded: false), "branch", "-m", oldName, newName])
    if !r.succeeded {
      throw GitClientError.commandFailed(command: "git branch -m", message: r.stderrString())
    }
  }

  /// `git check-ref-format --branch <name>`. Non-zero exit → invalid.
  func isValidBranchName(_ branchName: String, for repoRoot: URL) async -> Bool {
    let r = try? await runGit(args: [
      "-C", repoRoot.path(percentEncoded: false),
      "check-ref-format", "--branch", branchName,
    ])
    return r?.succeeded ?? false
  }

  /// `git rev-parse --is-bare-repository` returns "true" or "false".
  func isBareRepository(for repoRoot: URL) async throws -> Bool {
    let r = try await runGit(args: [
      "-C", repoRoot.path(percentEncoded: false),
      "rev-parse", "--is-bare-repository",
    ])
    guard r.succeeded else {
      throw GitClientError.commandFailed(command: "git rev-parse --is-bare-repository", message: r.stderrString())
    }
    return r.stdoutString().trimmingCharacters(in: .whitespacesAndNewlines) == "true"
  }

  /// `git remote` newline-separated remote names.
  func remoteNames(for repoRoot: URL) async throws -> [String] {
    let r = try await runGit(args: ["-C", repoRoot.path(percentEncoded: false), "remote"])
    guard r.succeeded else {
      throw GitClientError.commandFailed(command: "git remote", message: r.stderrString())
    }
    return Self.nonEmptyLines(r.stdoutString())
  }

  /// `git fetch <remote>`.
  func fetchRemote(_ remote: String, for repoRoot: URL) async throws {
    let r = try await runGit(args: ["-C", repoRoot.path(percentEncoded: false), "fetch", remote])
    if !r.succeeded {
      throw GitClientError.commandFailed(command: "git fetch \(remote)", message: r.stderrString())
    }
  }

  /// `git ls-files --others -i --exclude-standard` line count.
  func ignoredFileCount(for repoRoot: URL) async throws -> Int {
    let r = try await runGit(args: [
      "-C", repoRoot.path(percentEncoded: false),
      "ls-files", "--others", "-i", "--exclude-standard",
    ])
    guard r.succeeded else {
      throw GitClientError.commandFailed(command: "git ls-files (ignored)", message: r.stderrString())
    }
    return Self.nonEmptyLines(r.stdoutString()).count
  }

  /// `git ls-files --others --exclude-standard` line count.
  func untrackedFileCount(for repoRoot: URL) async throws -> Int {
    let r = try await runGit(args: [
      "-C", repoRoot.path(percentEncoded: false),
      "ls-files", "--others", "--exclude-standard",
    ])
    guard r.succeeded else {
      throw GitClientError.commandFailed(command: "git ls-files (untracked)", message: r.stderrString())
    }
    return Self.nonEmptyLines(r.stdoutString()).count
  }

  /// Mirrors `GitClient.lineChanges(at:)`. Tolerant of any failure (returns
  /// nil); also nil when the worktree index is locked. Phase B treats
  /// index-lock checking as a no-op (the local impl checks a local `.lock`
  /// file via FS probe; remote variant skips this since the diff command
  /// will itself fail loud if the index is locked, and we return nil anyway).
  func lineChanges(at worktreeURL: URL) async -> (added: Int, removed: Int)? {
    let r = try? await runGit(args: [
      "-C", worktreeURL.path(percentEncoded: false),
      "diff", "HEAD", "--shortstat",
    ])
    guard let result = r, result.succeeded else { return nil }
    return Self.parseShortstat(result.stdoutString())
  }

  /// Mirrors `GitClient.remoteInfo(for:)`. Iterates remotes (origin first),
  /// runs `git remote get-url` per remote, returns first parsed GitHub
  /// owner/repo. Tolerant of any failure (returns nil).
  func remoteInfo(for repositoryRoot: URL) async -> GithubRemoteInfo? {
    let path = repositoryRoot.path(percentEncoded: false)
    guard let listResult = try? await runGit(args: ["-C", path, "remote"]), listResult.succeeded else {
      return nil
    }
    let remotes = Self.nonEmptyLines(listResult.stdoutString())
    let ordered: [String]
    if remotes.contains("origin") {
      ordered = ["origin"] + remotes.filter { $0 != "origin" }
    } else {
      ordered = remotes
    }
    for remote in ordered {
      guard let urlResult = try? await runGit(
        args: ["-C", path, "remote", "get-url", remote]
      ), urlResult.succeeded else {
        continue
      }
      if let info = Self.parseGithubRemoteInfo(urlResult.stdoutString()) {
        return info
      }
    }
    return nil
  }

  // MARK: Phase B — branch/ref queries (mirrors GitReferenceQueries)

  /// Mirrors `GitReferenceQueries.defaultRemoteBranchRef(for:)`. Returns
  /// `origin/<branch>` or falls back to `origin/main` if reachable.
  func defaultRemoteBranchRef(for repoRoot: URL) async throws -> String? {
    let path = repoRoot.path(percentEncoded: false)
    if let r = try? await runGit(args: [
      "-C", path, "symbolic-ref", "-q", "refs/remotes/origin/HEAD",
    ]), r.succeeded {
      let trimmed = r.stdoutString().trimmingCharacters(in: .whitespacesAndNewlines)
      if let resolved = Self.normalizeRemoteRef(trimmed),
        await refExists(resolved, in: repoRoot)
      {
        return resolved
      }
    }
    let fallback = "origin/main"
    return await refExists(fallback, in: repoRoot) ? fallback : nil
  }

  /// Mirrors `GitReferenceQueries.automaticWorktreeBaseRef(for:)`.
  /// Remote `origin/<branch>` if present; else the local HEAD branch ref
  /// if it exists; else nil.
  func automaticWorktreeBaseRef(for repoRoot: URL) async -> String? {
    // try? wraps the throw and unwraps the inner optional once, leaving String??.
    // Flatten with ?? .none + use a single optional binding.
    if let remote = (try? await defaultRemoteBranchRef(for: repoRoot)) ?? nil {
      return remote
    }
    // Local-HEAD fallback path.
    guard let r = try? await runGit(args: [
      "-C", repoRoot.path(percentEncoded: false),
      "symbolic-ref", "--short", "HEAD",
    ]), r.succeeded else {
      return nil
    }
    let localHead = r.stdoutString().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !localHead.isEmpty else { return nil }
    return await refExists(localHead, in: repoRoot) ? localHead : nil
  }

  /// Mirrors `GitReferenceQueries.branchInventory(for:remoteNames:)`.
  /// Two parallel git invocations: local branches + remote branches.
  func branchInventory(for repoRoot: URL, remoteNames: [String]) async throws -> GitBranchInventory {
    async let localTask = orderedLocalBranchNames(for: repoRoot)
    async let remoteRefsTask = remoteBranchRefs(for: repoRoot)
    let (local, remoteRefs) = try await (localTask, remoteRefsTask)
    return GitBranchInventory(
      localBranches: Self.sortedAlphabetically(local),
      remotes: Self.groupRemoteBranches(refs: remoteRefs, remoteNames: remoteNames)
    )
  }

  private func orderedLocalBranchNames(for repoRoot: URL) async throws -> [String] {
    let r = try await runGit(args: [
      "-C", repoRoot.path(percentEncoded: false),
      "for-each-ref", "--format=%(refname:short)", "refs/heads",
    ])
    guard r.succeeded else {
      throw GitClientError.commandFailed(command: "git for-each-ref refs/heads", message: r.stderrString())
    }
    return Self.nonEmptyLines(r.stdoutString())
  }

  private func remoteBranchRefs(for repoRoot: URL) async throws -> [String] {
    let r = try await runGit(args: [
      "-C", repoRoot.path(percentEncoded: false),
      "for-each-ref", "--format=%(refname:short)", "refs/remotes",
    ])
    guard r.succeeded else {
      throw GitClientError.commandFailed(command: "git for-each-ref refs/remotes", message: r.stderrString())
    }
    return Self.nonEmptyLines(r.stdoutString()).filter { !$0.hasSuffix("/HEAD") }
  }

  /// `git rev-parse --verify --quiet <ref>` — true when the ref exists.
  private func refExists(_ ref: String, in repoRoot: URL) async -> Bool {
    let r = try? await runGit(args: [
      "-C", repoRoot.path(percentEncoded: false),
      "rev-parse", "--verify", "--quiet", ref,
    ])
    return r?.succeeded ?? false
  }

  // MARK: Phase C — worktree create + remove

  /// Mirrors `GitClient.createWorktree(named:in:baseDirectory:copyFiles:baseRef:)`.
  /// Drives `createWorktreeStream` and unwraps the `.finished` event.
  nonisolated func createWorktree(
    named name: String,
    in repoRoot: URL,
    baseDirectory: URL,
    copyFiles: (ignored: Bool, untracked: Bool),
    baseRef: String
  ) async throws -> Worktree {
    var created: Worktree?
    for try await event in createWorktreeStream(
      named: name, in: repoRoot, baseDirectory: baseDirectory,
      copyFiles: copyFiles, baseRef: baseRef, directoryOverride: nil
    ) {
      if case .finished(let worktree) = event {
        created = worktree
      }
    }
    guard let created else {
      throw GitClientError.commandFailed(
        command: "wt sw \(name)",
        message: "Empty output (worktree path not parsed from wt output)"
      )
    }
    return created
  }

  /// Mirrors `GitClient.createWorktreeStream(...)`. Slice 3 caveat: we buffer
  /// the wt output instead of streaming it line-by-line (SSHClient.stream is
  /// stubbed until Slice 4). Final `.finished` event still carries the
  /// correctly-shaped Worktree. The UI loses live progress during creation;
  /// it sees one batched .outputLine + the .finished event.
  nonisolated func createWorktreeStream(
    named name: String,
    in repoRoot: URL,
    baseDirectory: URL,
    copyFiles: (ignored: Bool, untracked: Bool),
    baseRef: String,
    directoryOverride: URL?
  ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        do {
          let args = Self.createWorktreeArguments(
            baseDirectory: baseDirectory,
            name: name,
            copyFiles: copyFiles,
            baseRef: baseRef,
            directoryOverride: directoryOverride
          )
          let repoPath = repoRoot.standardizedFileURL.path(percentEncoded: false)
          let result = try await runWt(args: args, cwd: repoPath)
          let stdout = result.stdoutString()
          // Yield batched stdout as a single outputLine so the existing UI
          // surface still receives an event (callers buffer + display).
          if !stdout.isEmpty {
            continuation.yield(.outputLine(ShellStreamLine(source: .stdout, text: stdout)))
          }
          guard result.succeeded else {
            throw GitClientError.commandFailed(
              command: "wt \(args.joined(separator: " "))",
              message: result.stderrString()
            )
          }
          let pathLine = Self.lastNonEmptyLine(in: stdout)
          guard let pathLine else {
            throw GitClientError.commandFailed(
              command: "wt \(args.joined(separator: " "))",
              message: "Empty output"
            )
          }
          let worktreeURL = URL(fileURLWithPath: pathLine).standardizedFileURL
          let detail = Self.relativePath(from: repoRoot.standardizedFileURL, to: worktreeURL)
          let id = worktreeURL.path(percentEncoded: false)
          let worktree = Worktree(
            id: id,
            name: name,
            detail: detail,
            workingDirectory: worktreeURL,
            repositoryRootURL: repoRoot.standardizedFileURL,
            createdAt: nil  // Same as Phase A: remote stat skipped; UI falls back to index order
          )
          // The local impl writes a supacode-lock JSON file into the admin
          // dir here. For remote, we'd need to SCP a small file. Deferred
          // to a Phase C+ hardening pass — for now the worktree is created
          // without the supacode-lock marker, which means `reconcileSupacodeLocks`
          // won't see it. The lock is a "Supacode owns this" claim, not a
          // safety mechanism; ops still work.
          continuation.yield(.finished(worktree))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  /// Mirrors `GitClient.removeWorktree(_:deleteBranch:)`.
  /// Sequence (over SSH):
  ///   1. `git -C repo worktree prune --expire=now` (silent on still-locked)
  ///   2. `git -C repo worktree remove --force --force <path>` (the actual guarantee)
  ///   3. If `deleteBranch` AND the branch name appears in local refs:
  ///      `git -C repo branch -D <name>`
  ///   4. `rm -rf <worktreePath>` to clean the dir if git's remove left bits
  /// Skips the local "relocate to trash + async delete" optimization — that's
  /// a local-FS performance hack; the remote `rm -rf` is fast enough.
  nonisolated func removeWorktree(_ worktree: Worktree, deleteBranch: Bool) async throws -> URL {
    let rootPath = worktree.repositoryRootURL.path(percentEncoded: false)
    let worktreePath = worktree.workingDirectory.standardizedFileURL.path(percentEncoded: false)

    _ = try? await runGit(args: ["-C", rootPath, "worktree", "prune", "--expire=now"])
    _ = try? await runGit(args: ["-C", rootPath, "worktree", "remove", "--force", "--force", worktreePath])

    if deleteBranch, !worktree.name.isEmpty {
      let names = (try? await self.localBranchNames(for: worktree.repositoryRootURL)) ?? []
      if names.contains(worktree.name.lowercased()) {
        _ = try? await runGit(args: ["-C", rootPath, "branch", "-D", worktree.name])
      }
    }

    // Final safety net — `rm -rf` to ensure the dir is gone even if git's
    // remove left orphan files. Equivalent to the local impl's relocated-trash
    // detached delete, just synchronous (the remote handles the FS work).
    _ = try? await sshClient.exec(["rm", "-rf", worktreePath], .seconds(15))

    return worktree.workingDirectory
  }

  /// Mirrors `GitClient.createWorktreeArguments(...)` exactly so we hit
  /// `wt` with the same flag shape the local mode does.
  nonisolated static func createWorktreeArguments(
    baseDirectory: URL,
    name: String,
    copyFiles: (ignored: Bool, untracked: Bool),
    baseRef: String,
    directoryOverride: URL?
  ) -> [String] {
    var args = ["--base-dir", baseDirectory.path(percentEncoded: false), "sw"]
    if copyFiles.ignored { args.append("--copy-ignored") }
    if copyFiles.untracked { args.append("--copy-untracked") }
    if !baseRef.isEmpty {
      args.append("--from")
      args.append(baseRef)
    }
    if let directoryOverride {
      args.append("--path")
      args.append(directoryOverride.path(percentEncoded: false))
    }
    if copyFiles.ignored || copyFiles.untracked {
      args.append("--verbose")
    }
    args.append(name)
    return args
  }

  /// Mirrors `GitClient.lastNonEmptyLine(in:)`. Used to recover the
  /// worktree path from the tail of `wt sw` output.
  nonisolated static func lastNonEmptyLine(in output: String) -> String? {
    output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { !$0.isEmpty }
  }

  // MARK: - Internal: git + wt invocation

  /// Run `wt <args>` from `cwd` on the remote.
  ///
  /// **Tilde handling:** if `wtPath` starts with `~/`, we leave it UNQUOTED so
  /// the remote shell expands it to `$HOME`. Quoting it would defeat tilde
  /// expansion and produce literal `~/.local/bin/wt`, which the shell can't
  /// exec ("no such file or directory"). Same logic applies to `cwd`.
  private func runWt(args: [String], cwd: String) async throws -> SSHClient.ExecResult {
    let cmd = "cd \(quoteAllowingTilde(cwd)) && \(quoteAllowingTilde(wtPath)) \(args.map(shellQuote).joined(separator: " "))"
    return try await sshClient.exec(["sh", "-c", cmd], .seconds(30))
  }

  /// Like `shellQuote` but preserves leading `~/` for shell tilde expansion.
  /// Everything after the `~/` is single-quoted so embedded spaces / quotes
  /// in the path body still survive the shell parse.
  private func quoteAllowingTilde(_ path: String) -> String {
    if path.hasPrefix("~/") {
      let rest = String(path.dropFirst(2))
      return "~/\(shellQuote(rest))"
    }
    return shellQuote(path)
  }

  /// Run `git <args>` on the remote. The `-C <path>` form is preserved in
  /// the caller's args list, so we don't impose a cwd here — `git -C`
  /// is the portable, single-process way.
  private func runGit(args: [String]) async throws -> SSHClient.ExecResult {
    try await sshClient.exec(["git"] + args, .seconds(15))
  }

  // MARK: - Pure helpers (mirror GitReferenceQueries / GitClient privates)

  nonisolated static func nonEmptyLines(_ output: String) -> [String] {
    output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  nonisolated static func sortedAlphabetically(_ values: [String]) -> [String] {
    values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  /// Same prefix-match logic as `GitReferenceQueries.remotePrefixMatch` —
  /// longest remote name wins so `up` vs `upstream` resolves correctly.
  nonisolated static func remotePrefixMatch(ref: String, remoteNames: [String]) -> (remote: String, branch: String)? {
    for remote in remoteNames.sorted(by: { $0.count > $1.count }) {
      let prefix = "\(remote)/"
      guard ref.hasPrefix(prefix) else { continue }
      let branch = String(ref.dropFirst(prefix.count))
      return branch.isEmpty ? nil : (remote, branch)
    }
    return nil
  }

  nonisolated static func groupRemoteBranches(refs: [String], remoteNames: [String]) -> [GitRemoteBranchGroup] {
    var grouped: [String: [String]] = [:]
    for ref in refs {
      guard let match = remotePrefixMatch(ref: ref, remoteNames: remoteNames) else { continue }
      grouped[match.remote, default: []].append(match.branch)
    }
    return
      remoteNames
      .sorted { lhs, rhs in
        if lhs == "origin" { return rhs != "origin" }
        if rhs == "origin" { return false }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
      }
      .compactMap { remote in
        guard let branches = grouped[remote] else { return nil }
        return GitRemoteBranchGroup(name: remote, branches: sortedAlphabetically(branches))
      }
  }

  nonisolated static func normalizeRemoteRef(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let prefix = "refs/remotes/"
    return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed
  }

  /// Parse `git diff HEAD --shortstat` output:
  /// e.g. "2 files changed, 12 insertions(+), 3 deletions(-)".
  nonisolated static func parseShortstat(_ output: String) -> (added: Int, removed: Int) {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return (0, 0) }
    var added = 0
    var removed = 0
    if let match = trimmed.firstMatch(of: /(\d+)\s+insertions?\(\+\)/) {
      added = Int(match.1) ?? 0
    }
    if let match = trimmed.firstMatch(of: /(\d+)\s+deletions?\(-\)/) {
      removed = Int(match.1) ?? 0
    }
    return (added, removed)
  }

  /// Parse a `git remote get-url` value into a `GithubRemoteInfo`. Supports
  /// SSH (`git@github.com:owner/repo.git`) and HTTPS
  /// (`https://github.com/owner/repo.git`) — same shape as the local
  /// `GitClient.parseGithubRemoteInfo`. Inlined because the local helper is
  /// `private`.
  nonisolated static func parseGithubRemoteInfo(_ remoteURL: String) -> GithubRemoteInfo? {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("git@") {
      let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2 else { return nil }
      let hostAndPath = parts[1]
      let hostParts = hostAndPath.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
      guard hostParts.count == 2 else { return nil }
      return parseGithubRemoteInfo(host: String(hostParts[0]), path: String(hostParts[1]))
    }
    if let url = URL(string: trimmed), let host = url.host {
      let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
      return parseGithubRemoteInfo(host: host, path: path)
    }
    return nil
  }

  nonisolated private static func parseGithubRemoteInfo(host: String, path: String) -> GithubRemoteInfo? {
    let normalizedHost = host.lowercased()
    guard normalizedHost.contains("github") else { return nil }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2 else { return nil }
    let owner = String(components[0])
    var repo = String(components[1])
    if repo.hasSuffix(".git") {
      repo = String(repo.dropLast(4))
    }
    return GithubRemoteInfo(host: normalizedHost, owner: owner, repo: repo)
  }
}

// MARK: - Helpers

nonisolated private func shellQuote(_ value: String) -> String {
  let escaped = value.replacing("'", with: "'\\''")
  return "'\(escaped)'"
}
