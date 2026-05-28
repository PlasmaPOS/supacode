import ComposableArchitecture
import Dependencies
import Foundation
import SupacodeSettingsShared

/// Bridges macOS-native "Open in Finder" / "Open in editor" actions to a
/// remote host. In local mode these are direct `NSWorkspace.shared.open(...)`
/// calls — for remote paths that's meaningless (the file lives on a different
/// machine), so we re-route through SSH.
///
/// `revealInFinder(path:)` runs `ssh remote -C "open '<path>'"`. The Finder
/// window pops on the **remote's GUI session**, not the laptop's. The user
/// views it via Mac Screen Sharing (set up once: `vnc://mini.tailnet`).
/// First-time use should show a one-shot tooltip about this — wiring that
/// tooltip is part of the caller's UI flow.
///
/// `openInEditor(path:)` uses VS Code Remote-SSH via `code` URL handler:
/// `vscode://vscode-remote/ssh-remote+<host>/<path>`. Requires the user to
/// have VS Code with the Remote-SSH extension installed (very common).
/// Falls back to the standard Finder reveal if the VS Code handler is
/// unregistered.
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
  /// Build a `RemoteOpenClient` for the given SSH host. The `sshHostString`
  /// is what VS Code's Remote-SSH needs (`user@host` or just `host` from
  /// `~/.ssh/config`); we pass `RemoteHost.sshTarget` for the user@host
  /// case.
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
        // VS Code Remote-SSH URL scheme:
        //   vscode://vscode-remote/ssh-remote+<host>/<absolute-path>
        // Path must be absolute and URL-encoded.
        let escapedHost = sshHost.sshTarget.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? sshHost.sshTarget
        let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let urlString = "vscode://vscode-remote/ssh-remote+\(escapedHost)\(escapedPath.hasPrefix("/") ? "" : "/")\(escapedPath)"
        guard let url = URL(string: urlString) else { return false }
        return NSWorkspace.shared.open(url)
      }
    )
  }

  /// Local-mode no-op variant — Finder and editor actions go through the
  /// existing local-FS code paths, not us. Returning `false` from each
  /// signals "I didn't handle this; caller fall back to default behavior."
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

#if canImport(AppKit)
  import AppKit
#endif

nonisolated private func shellQuote(_ value: String) -> String {
  let escaped = value.replacing("'", with: "'\\''")
  return "'\(escaped)'"
}
