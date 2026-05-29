import Foundation

/// Errors raised by `SSHClient` and the remote-mode clients layered on top of
/// it. Each case is independently actionable — the UI banner / settings
/// reconnect button can branch on `case` without re-parsing strings.
public enum RemoteError: Error, Equatable, Sendable {
  /// We attempted to use remote mode but no `RemoteHost` is configured.
  case notConfigured

  /// The local `ssh` binary couldn't be found in PATH.
  case sshClientMissing

  /// `ssh -O check` reported the ControlMaster channel is down. The caller
  /// can choose to surface this or transparently retry once.
  case masterDown

  /// `ssh` exited with a non-zero status that suggests a connection-level
  /// problem (host unreachable, auth refused, etc.) rather than the remote
  /// command failing on its own merits.
  case connectionFailed(exitCode: Int32, stderr: String)

  /// Process spawn failed locally (rare — usually a sandbox / signing issue).
  case spawnFailed(underlying: String)

  /// We hit our internal timeout waiting for `ssh` to return.
  case timeout(after: Duration)

  /// The caller asked us to read a file larger than `SSHClient`'s soft cap
  /// (`SSHClient.readFileMaxBytes`). The file size in bytes is included so
  /// the caller can decide whether to escalate to a streaming read.
  case fileTooLarge(bytes: Int)

  /// The remote process exited with a non-zero status. Distinct from
  /// `connectionFailed` so callers can tell "git refused" apart from
  /// "couldn't reach the host." `stderr` is captured for surfacing.
  case remoteCommandFailed(exitCode: Int32, stderr: String)
}

extension RemoteError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "No remote host is configured."
    case .sshClientMissing:
      return "OpenSSH client (`ssh`) is not available in PATH."
    case .masterDown:
      return "The SSH ControlMaster channel is not responding."
    case .connectionFailed(let exit, let stderr):
      return "SSH connection failed (exit \(exit)). \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    case .spawnFailed(let underlying):
      return "Failed to spawn ssh: \(underlying)"
    case .timeout(let after):
      return "Remote call timed out after \(after)."
    case .fileTooLarge(let bytes):
      return "Remote file is too large to inline-read (\(bytes) bytes)."
    case .remoteCommandFailed(let exit, let stderr):
      return "Remote command failed (exit \(exit)). \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
  }
}
