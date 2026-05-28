import ComposableArchitecture
import Dependencies
import Foundation
import SupacodeSettingsShared

extension WorktreeInfoWatcherClient {
  /// Remote variant of the watcher: polls the remote worktrees over SSH on a
  /// fixed cadence and emits `branchChanged` + `filesChanged` events when
  /// HEAD or working-tree status changes.
  ///
  /// Diverges from `.liveValue` in two ways, documented inline:
  /// 1. **Polling instead of file events.** `liveValue` uses
  ///    `DispatchSourceFileSystemObject` on local HEAD files for sub-second
  ///    reaction. Remote can't do that until `SSHClient.stream` lands
  ///    (Slice 4 follow-up); we poll every 3 seconds for now. The
  ///    UX difference is "sidebar updates within 3s after a remote `git
  ///    checkout`" instead of "instantly." Acceptable for v1.
  /// 2. **PR refresh schedule:** mirrors `liveValue` shape (`focused`/
  ///    `unfocused` intervals + selection-cooldown), but the actual data
  ///    fetch hops through the already-remote `GitClient` via
  ///    `RepositoryGithubFeature`, so no surgery is needed beyond
  ///    re-emitting the `repositoryPullRequestRefresh` event on schedule.
  ///
  /// Slice 4 v1 ships only branch + files polling. PR refresh schedule is
  /// emitted on a fixed 60s cadence (the local impl varies focused/unfocused;
  /// remote follow-up can wire that if it matters in practice).
  ///
  /// `pollInterval` is overrideable so tests can drive deterministic ticks.
  nonisolated static func remote(
    sshClient: SSHClient,
    pollInterval: Duration = .seconds(3),
    pullRequestRefreshInterval: Duration = .seconds(60)
  ) -> WorktreeInfoWatcherClient {
    let manager = RemoteWatcherManager(
      sshClient: sshClient,
      pollInterval: pollInterval,
      pullRequestRefreshInterval: pullRequestRefreshInterval
    )
    return WorktreeInfoWatcherClient(
      send: { command in
        Task { await manager.handle(command) }
      },
      events: { manager.events }
    )
  }
}

/// Actor that owns the per-worktree polling tasks for remote mode. Pure
/// in-memory — no FS state — so it can be torn down by simply dropping
/// the actor.
private actor RemoteWatcherManager {
  private let sshClient: SSHClient
  private let pollInterval: Duration
  private let pullRequestRefreshInterval: Duration

  /// Last-seen HEAD ref per worktree. First poll establishes the baseline
  /// without emitting (otherwise every newly-watched worktree would emit a
  /// spurious branchChanged on attach).
  private var lastHead: [Worktree.ID: String] = [:]

  /// Last-seen `git status --porcelain` hash per worktree. Same baseline
  /// rule as `lastHead`.
  private var lastStatusHash: [Worktree.ID: Int] = [:]

  /// Per-worktree polling tasks. Cancelled in `stop()` and when a worktree
  /// leaves the watched set.
  private var pollTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var prRefreshTasks: [URL: Task<Void, Never>] = [:]

  /// In-flight worktree set, kept so we can re-derive PR-refresh schedules
  /// when worktrees join/leave.
  private var watchedWorktrees: [Worktree.ID: Worktree] = [:]
  private var selectedWorktreeID: Worktree.ID?
  private var pullRequestTrackingEnabled = false

  /// Event continuation. Single shared stream; multiple subscribers not
  /// supported (matches the local manager's contract). `nonisolated` so the
  /// `WorktreeInfoWatcherClient.events` closure can read it without hopping
  /// onto the actor (AsyncStream is Sendable and the stream identity is
  /// fixed at init).
  nonisolated let events: AsyncStream<WorktreeInfoWatcherClient.Event>
  nonisolated private let eventContinuation: AsyncStream<WorktreeInfoWatcherClient.Event>.Continuation

  init(
    sshClient: SSHClient,
    pollInterval: Duration,
    pullRequestRefreshInterval: Duration
  ) {
    self.sshClient = sshClient
    self.pollInterval = pollInterval
    self.pullRequestRefreshInterval = pullRequestRefreshInterval
    var continuation: AsyncStream<WorktreeInfoWatcherClient.Event>.Continuation!
    self.events = AsyncStream { continuation = $0 }
    self.eventContinuation = continuation
  }

  func handle(_ command: WorktreeInfoWatcherClient.Command) {
    switch command {
    case .setWorktrees(let worktrees):
      setWorktrees(worktrees)
    case .setSelectedWorktreeID(let id):
      selectedWorktreeID = id
    case .setPullRequestTrackingEnabled(let enabled):
      pullRequestTrackingEnabled = enabled
      rebuildPRRefreshSchedules()
    case .stop:
      stopAll()
    }
  }

  // MARK: - Worktree polling

  private func setWorktrees(_ worktrees: [Worktree]) {
    let newIDs = Set(worktrees.map(\.id))
    let oldIDs = Set(watchedWorktrees.keys)
    // Stop polls for worktrees that left the set.
    for goneID in oldIDs.subtracting(newIDs) {
      pollTasks[goneID]?.cancel()
      pollTasks[goneID] = nil
      lastHead[goneID] = nil
      lastStatusHash[goneID] = nil
    }
    // Start polls for newly-watched worktrees.
    watchedWorktrees = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0) })
    for worktree in worktrees where pollTasks[worktree.id] == nil {
      pollTasks[worktree.id] = Task { [weak self] in
        await self?.pollLoop(for: worktree)
      }
    }
    rebuildPRRefreshSchedules()
  }

  private func pollLoop(for worktree: Worktree) async {
    while !Task.isCancelled {
      await pollOnce(worktree: worktree)
      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        return  // cancelled
      }
    }
  }

  private func pollOnce(worktree: Worktree) async {
    let path = worktree.workingDirectory.path(percentEncoded: false)
    // Two ops in parallel via async let.
    async let headResult = sshClient.exec(
      ["sh", "-c", "cd \(shellQuote(path)) && git rev-parse HEAD 2>/dev/null"],
      .seconds(5)
    )
    async let statusResult = sshClient.exec(
      ["sh", "-c", "cd \(shellQuote(path)) && git status --porcelain 2>/dev/null"],
      .seconds(5)
    )

    if let head = (try? await headResult)?.stdoutString().trimmingCharacters(in: .whitespacesAndNewlines),
      !head.isEmpty
    {
      let last = lastHead[worktree.id]
      lastHead[worktree.id] = head
      if let last, last != head {
        emit(.branchChanged(worktreeID: worktree.id))
      }
    }

    if let status = (try? await statusResult)?.stdoutString() {
      // Hash the porcelain output; cheap + collision-resistant enough that
      // we don't care about the tiny false-negative rate.
      let hash = status.hashValue
      let last = lastStatusHash[worktree.id]
      lastStatusHash[worktree.id] = hash
      if let last, last != hash {
        emit(.filesChanged(worktreeID: worktree.id))
      }
    }
  }

  // MARK: - PR refresh

  private func rebuildPRRefreshSchedules() {
    // Cancel everything; rebuild fresh from `watchedWorktrees` + flag.
    for task in prRefreshTasks.values { task.cancel() }
    prRefreshTasks = [:]
    guard pullRequestTrackingEnabled else { return }
    let byRepo = Dictionary(grouping: watchedWorktrees.values) { $0.repositoryRootURL }
    for (repoRoot, worktrees) in byRepo {
      let ids = worktrees.map(\.id)
      prRefreshTasks[repoRoot] = Task { [weak self] in
        await self?.prRefreshLoop(repoRoot: repoRoot, worktreeIDs: ids)
      }
    }
  }

  private func prRefreshLoop(repoRoot: URL, worktreeIDs: [Worktree.ID]) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: pullRequestRefreshInterval)
      } catch {
        return
      }
      emit(.repositoryPullRequestRefresh(repositoryRootURL: repoRoot, worktreeIDs: worktreeIDs))
    }
  }

  // MARK: - Lifecycle

  private func stopAll() {
    for task in pollTasks.values { task.cancel() }
    for task in prRefreshTasks.values { task.cancel() }
    pollTasks = [:]
    prRefreshTasks = [:]
    lastHead = [:]
    lastStatusHash = [:]
    watchedWorktrees = [:]
  }

  private func emit(_ event: WorktreeInfoWatcherClient.Event) {
    eventContinuation.yield(event)
  }
}

// MARK: - Shell helpers

nonisolated private func shellQuote(_ value: String) -> String {
  let escaped = value.replacing("'", with: "'\\''")
  return "'\(escaped)'"
}
