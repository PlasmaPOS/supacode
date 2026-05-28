import ComposableArchitecture
import Dependencies
import Foundation
import SupacodeSettingsShared

extension ZmxClient {
  /// Build a `ZmxClient` whose persistent session daemon lives on a remote
  /// host. Ghostty surfaces still spawn a LOCAL PTY — that PTY just runs
  /// `ssh user@host -t -- zmx attach <id> <cmd>` instead of the local zmx.
  /// The remote zmx daemon outlives Supacode, the SSH connection, and even
  /// the laptop — only `sleep`/reboot of the remote ends a session.
  ///
  /// Failure model: if SSH is down or remote zmx is missing, `wrapCommand`
  /// still returns a command string (we let Ghostty try; the user sees the
  /// "ssh: connect: Connection refused" or similar in their tab and can
  /// retry from the settings panel). `killSession`/`listSessions` route
  /// through `SSHClient.exec` and surface remote-exec failures via the
  /// existing `runZmx` log path.
  ///
  /// `zmxBinaryPath` is where the remote zmx binary lives — Slice 7's
  /// bootstrap installs it at `~/.local/bin/zmx` by default; tests can
  /// override.
  nonisolated static func remote(
    sshClient: SSHClient,
    zmxBinaryPath: String = "~/.local/bin/zmx",
    remoteSocketDir: String? = nil
  ) -> ZmxClient {
    let socketDirOption: String = remoteSocketDir.map { "ZMX_DIR=\($0)" } ?? ""

    return ZmxClient(
      executableURL: {
        // Not meaningful in remote mode — the binary lives on the remote.
        // Returning nil lets callers that wanted the local path fall through
        // gracefully (none of the current callers actually need this in
        // remote mode; we audit again post-Slice 3).
        nil
      },
      isBundled: {
        // In remote mode "bundled" means "we expect the remote to have zmx".
        // Slice 7's bootstrap is what makes this true; we trust it here. If
        // it's lying, `killSession`/`listSessions` will fail loudly the
        // first time they're called.
        true
      },
      wrapCommand: { sessionID, userCommand in
        ZmxRemoteAttach.buildCommand(
          sshClient: sshClient,
          remoteZmxBinary: zmxBinaryPath,
          remoteSocketDirOption: socketDirOption,
          sessionID: sessionID,
          userCommand: userCommand
        )
      },
      killSession: { sessionID in
        do {
          var argv = [zmxBinaryPath, "kill", sessionID]
          if !socketDirOption.isEmpty {
            argv = ["sh", "-c", "\(socketDirOption) \(argv.map(shellQuote).joined(separator: " "))"]
          }
          _ = try await sshClient.exec(argv, .seconds(5))
        } catch {
          sshLogger.warning("remote zmx kill \(sessionID) failed: \(error)")
        }
      },
      listSessions: {
        do {
          var argv = [zmxBinaryPath, "ls", "--short"]
          if !socketDirOption.isEmpty {
            argv = ["sh", "-c", "\(socketDirOption) \(argv.map(shellQuote).joined(separator: " "))"]
          }
          let result = try await sshClient.exec(argv, .seconds(5))
          guard result.succeeded else {
            sshLogger.warning("remote zmx ls exit=\(result.exitCode) stderr=\(result.stderrString())")
            return []
          }
          return
            result.stdoutString()
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(ZmxSessionID.prefix) && !$0.isEmpty }
        } catch {
          sshLogger.warning("remote zmx ls threw: \(error)")
          return []
        }
      }
    )
  }
}

/// Builds the shell string handed to Ghostty's `config.command` for a remote
/// zmx-wrapped session. Pure; no I/O, no SSH dials. Same separation of
/// concerns as the local `ZmxAttach` namespace, so tests can verify the
/// generated command string without needing a live host.
nonisolated enum ZmxRemoteAttach {
  /// Compose the full `ssh ... zmx attach ...` invocation Ghostty will spawn.
  ///
  /// Delegates the ssh-prefix construction to `SSHClient.buildPTYCommand`
  /// so the same per-host config, ControlMaster socket, port, and identity
  /// file the rest of `SSHClient` uses are reused here. Pure with respect
  /// to the inputs — no I/O.
  ///
  /// Returns `nil` when the supplied `sshClient` is `.unconfigured`
  /// (callers should treat this as "remote mode broken; fall through to
  /// a local shell or surface the disconnect").
  nonisolated static func buildCommand(
    sshClient: SSHClient,
    remoteZmxBinary: String,
    remoteSocketDirOption: String,
    sessionID: String,
    userCommand: String?
  ) -> String? {
    let remoteCommand = buildRemoteCommand(
      remoteZmxBinary: remoteZmxBinary,
      remoteSocketDirOption: remoteSocketDirOption,
      sessionID: sessionID,
      userCommand: userCommand
    )
    return sshClient.buildPTYCommand(remoteCommand)
  }

  /// The inner command — what runs on the remote inside `sh -c`. Excluding
  /// the ssh prefix so tests can verify just the remote payload.
  nonisolated static func buildRemoteCommand(
    remoteZmxBinary: String,
    remoteSocketDirOption: String,
    sessionID: String,
    userCommand: String?
  ) -> String {
    let envPrefix = remoteSocketDirOption.isEmpty ? "" : "\(remoteSocketDirOption) "
    let zmxQuoted = shellQuote(remoteZmxBinary)
    let attach = "\(envPrefix)\(zmxQuoted) attach \(sessionID)"
    guard let command = userCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
      !command.isEmpty
    else {
      return attach
    }
    return "\(attach) /bin/sh -c \(shellQuote(command))"
  }
}

// MARK: - Helpers (mirror ZmxClient.swift's shell quoting so tests stay self-contained)

nonisolated private func shellQuote(_ value: String) -> String {
  let escaped = value.replacing("'", with: "'\\''")
  return "'\(escaped)'"
}

nonisolated private let sshLogger = SupaLogger("Zmx.Remote")
