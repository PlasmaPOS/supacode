import ComposableArchitecture
import Dependencies
import Foundation
import SupacodeSettingsShared

#if canImport(AppKit)
  import AppKit
#endif

/// Bridges macOS-native "Open in Finder" / "Open in editor" actions to a
/// remote host. In local mode these are direct `NSWorkspace.shared.open(...)`
/// calls — for remote paths that's meaningless (the file lives on a different
/// machine), so we re-route through SSH.
///
/// `revealInFinder(path:)` runs `ssh remote -C "open '<path>'"`. The Finder
/// window pops on the **remote's GUI session**, not the laptop's. The user
/// views it via Mac Screen Sharing (set up once: `vnc://mini.tailnet`).
///
/// `openInEditor(path:)` uses VS Code Remote-SSH via `code` URL handler:
/// `vscode://vscode-remote/ssh-remote+<host>/<path>`. Requires the user to
/// have VS Code with the Remote-SSH extension installed.
struct RemoteOpenClient: Sendable {
  /// Opens Finder on the remote pointing at `path`. Returns `true` if the
  /// SSH command exec'd cleanly (Finder spawn is fire-and-forget on the
  /// remote side; we don't wait for the window to appear).
  var revealInFinder: @Sendable (_ path: String) async -> Bool

  /// Opens VS Code Remote-SSH locally, pointing at the remote path. This is
  /// a LOCAL `NSWorkspace` call against a `vscode://...` URL — the SSH happens
  /// inside VS Code via its Remote-SSH extension. Returns `true` if VS Code
  /// claims the URL.
  var openInEditor: @Sendable (_ path: String) -> Bool
}

extension RemoteOpenClient {
  nonisolated static func live(
    sshClient: SSHClient,
    sshHost: RemoteHost
  ) -> RemoteOpenClient {
    RemoteOpenClient(
      revealInFinder: { path in
        let result = try? await sshClient.exec(
          ["sh", "-c", "open \(shellQuote(path))"],
          .seconds(5)
        )
        return result?.succeeded ?? false
      },
      openInEditor: { path in
        let urlString = vscodeRemoteSSHURL(sshTarget: sshHost.sshTarget, path: path)
        guard let url = URL(string: urlString) else { return false }
        #if canImport(AppKit)
          return NSWorkspace.shared.open(url)
        #else
          return false
        #endif
      }
    )
  }

  /// Local-mode no-op variant — returning `false` from each closure signals
  /// "I didn't handle this; caller falls back to the default local-FS path."
  nonisolated static let unavailable = RemoteOpenClient(
    revealInFinder: { _ in false },
    openInEditor: { _ in false }
  )
}

extension RemoteOpenClient: DependencyKey {
  nonisolated static let liveValue: RemoteOpenClient = .unavailable
  nonisolated static let testValue: RemoteOpenClient = .unavailable
}

extension DependencyValues {
  nonisolated var remoteOpenClient: RemoteOpenClient {
    get { self[RemoteOpenClient.self] }
    set { self[RemoteOpenClient.self] = newValue }
  }
}

// MARK: - Pure helpers (exposed for tests)

extension RemoteOpenClient {
  /// POSIX-safe single-quote wrap. Handles embedded single quotes via the
  /// standard `'\''` escape so the resulting string can be pasted into any
  /// `sh -c` invocation without further escaping.
  nonisolated static func shellQuote(_ value: String) -> String {
    let escaped = value.replacing("'", with: "'\\''")
    return "'\(escaped)'"
  }

  /// Build the `vscode://vscode-remote/ssh-remote+<host><path>` URL VS Code's
  /// Remote-SSH extension expects. Path is percent-encoded for `.urlPathAllowed`
  /// so spaces, unicode, etc. all survive the URL round-trip. We guarantee
  /// exactly one `/` separates the host and path.
  nonisolated static func vscodeRemoteSSHURL(sshTarget: String, path: String) -> String {
    let escapedHost = sshTarget.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? sshTarget
    let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    let separator = escapedPath.hasPrefix("/") ? "" : "/"
    return "vscode://vscode-remote/ssh-remote+\(escapedHost)\(separator)\(escapedPath)"
  }
}
