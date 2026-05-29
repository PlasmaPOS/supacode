import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension ShellClient {
  /// Build a `ShellClient` that runs every command on the remote via the
  /// given `SSHClient`. The `executableURL.path(percentEncoded: false)`
  /// becomes the program name on the remote — i.e. callers that pass
  /// `URL(fileURLWithPath: "/usr/local/bin/gh")` get `gh` exec'd at that
  /// remote path (which is fine when the remote has gh in the same
  /// canonical location; the GithubCLIClient resolver runs `which gh`
  /// over this very shell to discover the correct remote path before any
  /// real call).
  ///
  /// `currentDirectoryURL` becomes `cd <path> && ...` so caller-side
  /// "cd the worktree first" semantics work unchanged.
  ///
  /// Stream methods (`runStream`, `runLoginStream`) buffer the result and
  /// yield a single `.finished` event — same caveat as the rest of Slice
  /// 4: real streaming wires in when `SSHClient.stream` lands.
  ///
  /// **What this unlocks**: `GithubCLIClient.live(shell: .remoteOverSSH(ssh))`
  /// gives us a fully remote-routed `gh` integration without rewriting
  /// any of `GithubCLIClient`'s 12 closures. Same for any future client
  /// that takes a `ShellClient`.
  nonisolated static func remoteOverSSH(_ sshClient: SSHClient) -> ShellClient {
    let runImpl: @Sendable (URL, [String], URL?) async throws -> ShellOutput = { executable, arguments, cwd in
      let exe = executable.path(percentEncoded: false)
      let argv = [exe] + arguments
      let quoted = argv.map(Self.shellQuote).joined(separator: " ")
      let cmd: String
      if let cwd {
        cmd = "cd \(Self.shellQuote(cwd.path(percentEncoded: false))) && \(quoted)"
      } else {
        cmd = quoted
      }
      let result = try await sshClient.exec(["sh", "-c", cmd], .seconds(30))
      let output = ShellOutput(
        stdout: result.stdoutString(),
        stderr: result.stderrString(),
        exitCode: result.exitCode
      )
      if result.exitCode != 0 {
        throw ShellClientError(
          command: quoted,
          stdout: output.stdout,
          stderr: output.stderr,
          exitCode: output.exitCode
        )
      }
      return output
    }

    return ShellClient(
      run: runImpl,
      runLoginImpl: { exe, args, cwd, _ in
        // Login-shell semantics are about sourcing .zshrc/.bashrc for PATH
        // resolution. Since we route through `sh -c` on the remote, the
        // remote's default PATH is already in effect; we don't need to
        // explicitly re-source. If a caller needs the remote's interactive
        // PATH, this is the seam to swap `sh -c` for `bash -lc` later.
        try await runImpl(exe, args, cwd)
      },
      runStream: { exe, args, cwd in
        AsyncThrowingStream { continuation in
          Task {
            do {
              let output = try await runImpl(exe, args, cwd)
              continuation.yield(.finished(output))
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
        }
      },
      runLoginStreamImpl: { exe, args, cwd, _ in
        AsyncThrowingStream { continuation in
          Task {
            do {
              let output = try await runImpl(exe, args, cwd)
              continuation.yield(.finished(output))
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
        }
      }
    )
  }

  nonisolated private static func shellQuote(_ value: String) -> String {
    let escaped = value.replacing("'", with: "'\\''")
    return "'\(escaped)'"
  }
}
