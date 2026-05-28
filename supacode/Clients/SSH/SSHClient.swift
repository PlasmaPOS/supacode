import ComposableArchitecture
import Dependencies
import Foundation
import SupacodeSettingsShared

nonisolated private let sshLogger = SupaLogger("SSH")

/// SSHClient is the single SSH abstraction every remote-mode client builds on.
///
/// Design notes:
///
/// - **OpenSSH client, not a Swift SSH library.** We spawn the system `ssh` /
///   `scp` binaries. Auth is via the user's ssh-agent. We do not handle
///   passwords. This keeps us out of the libssh2 / NIOSSH dependency mess and
///   matches user expectations (the same `ssh user@host` they'd type
///   manually).
///
/// - **One ControlMaster per host for the process lifetime.** We write a
///   minimal `~/.ssh/supacode_config` on first use and reference it via
///   `ssh -F <path>`. Every `exec` / `readFile` / `writeFile` multiplexes
///   over that one TCP channel — no per-call handshake cost. The master is
///   reused for `ControlPersist=10m` after the last channel closes.
///
/// - **Hot read cache for `readFile`.** GitClient's remote-ization will call
///   `readFile` dozens of times per repo refresh (HEAD ref, gitdir pointer,
///   supacode-lock content, etc). We keep a 5-second per-path cache that the
///   caller can bypass with `bypassCache: true`. This is what makes the
///   remote GitClient fast enough to feel local.
///
/// - **Failure model.** All errors are `RemoteError` (q.v.). Callers don't
///   need to parse ssh stderr strings to decide between "host down" and "git
///   exited 1" — the distinction is encoded in the case.
struct SSHClient: Sendable {
  /// Run a one-shot command on the remote. Returns captured stdout/stderr +
  /// the exit status. `timeout` defaults to `defaultExecTimeout` (30s); pass
  /// `nil` for unbounded.
  ///
  /// `argv[0]` is the remote command (e.g. `"git"`); the rest are arguments.
  /// We shell-quote arguments before splicing into the ssh command line so
  /// callers don't need to think about it.
  var exec: @Sendable (_ argv: [String], _ timeout: Duration?) async throws -> ExecResult

  /// Stream a long-running command's stdout line by line. Cancellation of the
  /// consuming task kills the remote process (SIGTERM via `ssh -O cancel`).
  ///
  /// Stubbed in Slice 1 (returns `throwing` "not implemented"). Slice 4
  /// fills this in for `WorktreeInfoWatcher.remote`.
  var stream: @Sendable (_ argv: [String]) -> AsyncThrowingStream<String, Error>

  /// Read a remote file (≤ `readFileMaxBytes`). Uses a 5-second per-path
  /// cache by default; pass `bypassCache: true` to force a fresh fetch.
  /// Throws `RemoteError.fileTooLarge` if the file exceeds the size cap.
  var readFile: @Sendable (_ path: String, _ bypassCache: Bool) async throws -> Data

  /// Atomically write `data` to `path`. Uses a temp file + `mv` so partial
  /// writes can't be observed.
  var writeFile: @Sendable (_ path: String, _ data: Data) async throws -> Void

  /// Watch a path tree for changes. Stubbed in Slice 1; Slice 4 wires the
  /// narrow HEAD-watch + git-status poll implementation.
  var watch: @Sendable (_ path: String) -> AsyncStream<WatchEvent>

  /// Current connection state. UI binds to this to show the green/yellow/red
  /// status dot.
  var connectionState: @Sendable () -> ConnectionState

  /// Drop the cached `readFile` results — typically wired to "user moved the
  /// app to the foreground" or "user explicitly hit reconnect."
  var invalidateCache: @Sendable () -> Void

  /// Build a shell-parseable command string that, when run as a LOCAL PTY
  /// (e.g. as Ghostty's `config.command`), opens an SSH connection to the
  /// configured remote and exec's `remoteCommand` over it.
  ///
  /// Used by `ZmxClient.remote` to wrap each Ghostty surface in
  /// `ssh user@host -t -- sh -c '<zmx attach ...>'`. Returns nil when the
  /// client is unconfigured (callers fall back to a local shell or surface
  /// a "remote unconfigured" message).
  ///
  /// The returned string uses the same per-host ssh config the rest of
  /// `SSHClient` does (ControlMaster reuse, identity file, port). Callers
  /// don't need to know any of those details.
  var buildPTYCommand: @Sendable (_ remoteCommand: String) -> String?
}

extension SSHClient {
  /// Default exec timeout. 30s covers normal git ops with comfortable margin;
  /// callers that know they're slow (e.g. `git fetch`) pass a longer value.
  nonisolated static let defaultExecTimeout: Duration = .seconds(30)

  /// `readFile` cap. Larger files should use streaming. 1 MB is plenty for
  /// every file we care about in remote-mode GitClient (HEAD refs, gitdir
  /// pointers, lock files — all tiny).
  nonisolated static let readFileMaxBytes: Int = 1 * 1024 * 1024

  /// Cache TTL for `readFile`. 5 seconds matches "user clicks around in the
  /// sidebar at human speed" — repeated reads of the same HEAD ref during a
  /// single sidebar refresh hit the cache, but stale data never lingers
  /// past the next user-perceptible interval.
  nonisolated static let readFileCacheTTL: Duration = .seconds(5)

  /// Shape of an `exec` result. `succeeded` is a convenience for the very
  /// common "exit 0" check. `nonisolated` throughout so the Sendable
  /// closures storing this value can pass it across actor boundaries.
  struct ExecResult: Equatable, Sendable {
    var stdout: Data
    var stderr: Data
    var exitCode: Int32

    nonisolated var succeeded: Bool { exitCode == 0 }

    /// Decode stdout as UTF-8, trimming trailing newlines (matches what
    /// every caller actually wants from `echo`-style output).
    nonisolated func stdoutString() -> String {
      let raw = String(data: stdout, encoding: .utf8) ?? ""
      return raw.trimmingCharacters(in: .newlines)
    }

    /// Decode stderr as UTF-8 without trimming (preserves line structure for
    /// log surfaces).
    nonisolated func stderrString() -> String {
      String(data: stderr, encoding: .utf8) ?? ""
    }
  }

  /// Watch event shape; intentionally minimal in Slice 1. Slice 4 fills in
  /// the typed event payload that `WorktreeInfoWatcher.remote` needs.
  struct WatchEvent: Equatable, Sendable {
    var path: String
  }

  /// Connection states surfaced to the UI status dot.
  enum ConnectionState: Equatable, Sendable {
    /// No remote host configured — Supacode is in local mode.
    case unconfigured
    /// ControlMaster is live and healthy.
    case connected
    /// We're attempting to rebuild the ControlMaster (transient).
    case reconnecting
    /// Last reachability check failed; commands will fail fast.
    case offline(reason: String)
  }
}

// MARK: - Dependency wiring

extension SSHClient: DependencyKey {
  /// `liveValue` defaults to `.unconfigured`. The app wires the real value at
  /// startup once it reads the persisted `RemoteHost` (or finds none, in
  /// which case `.unconfigured` is correct).
  nonisolated static let liveValue: SSHClient = .unconfigured

  /// Tests get the no-op variant. Specific tests override with
  /// `.fake(...)` (see SSHClient+Fake.swift in the test target).
  nonisolated static let testValue: SSHClient = .unconfigured
}

extension DependencyValues {
  nonisolated var sshClient: SSHClient {
    get { self[SSHClient.self] }
    set { self[SSHClient.self] = newValue }
  }
}

// MARK: - Unconfigured (local-mode) implementation

extension SSHClient {
  /// The implementation injected when Supacode is in local mode. Every
  /// remote call throws `.notConfigured` so callers that wrongly assumed
  /// remote mode fail loudly instead of silently.
  nonisolated static let unconfigured: SSHClient = SSHClient(
    exec: { _, _ in throw RemoteError.notConfigured },
    stream: { _ in
      AsyncThrowingStream { continuation in
        continuation.finish(throwing: RemoteError.notConfigured)
      }
    },
    readFile: { _, _ in throw RemoteError.notConfigured },
    writeFile: { _, _ in throw RemoteError.notConfigured },
    watch: { _ in AsyncStream { $0.finish() } },
    connectionState: { .unconfigured },
    invalidateCache: {},
    buildPTYCommand: { _ in nil }
  )
}
