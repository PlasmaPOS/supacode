import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

extension GithubCLIClient {
  /// Remote variant: delegates to `GithubCLIClient.live(shell:)` with a
  /// SSH-over-shell adapter. All 12 closures (defaultBranch, latestRun,
  /// batchPullRequests, mergePullRequest, etc.) inherit the live
  /// implementation for free.
  ///
  /// Requires `gh` to be installed on the remote and `gh auth login` to
  /// have been run there once. Slice 7's bootstrap can detect both.
  // `GithubCLIClient.live(shell:)` is MainActor-isolated, so this factory
  // must be MainActor too. Callers wire it during app setup which is also
  // on MainActor, so the constraint costs nothing.
  @MainActor static func remote(sshClient: SSHClient) -> GithubCLIClient {
    .live(shell: .remoteOverSSH(sshClient))
  }
}
