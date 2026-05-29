import ComposableArchitecture
import Dependencies
import SwiftUI

/// Tiny pill that surfaces SSH connection health when remote mode is active.
/// Renders nothing in local mode (the `@Dependency(\.sshClient)` resolves to
/// the `.unconfigured` factory).
///
/// Polls every 4s — cheap because `SSHClient.connectionState` returns from a
/// short in-memory cache. The poll keeps the cache fresh so a downed
/// ControlMaster is surfaced within ~4–9s.
struct RemoteConnectionBanner: View {
  @Dependency(\.sshClient) private var sshClient
  @State private var state: SSHClient.ConnectionState = .unconfigured
  @State private var poller: Task<Void, Never>?

  var body: some View {
    Group {
      switch state {
      case .unconfigured:
        EmptyView()
      case .connected:
        chip(color: .green, label: "Remote", icon: "link")
      case .reconnecting:
        chip(color: .orange, label: "Reconnecting…", icon: "ellipsis")
      case .offline(let reason):
        chip(color: .red, label: "Offline", icon: "link.badge.minus")
          .help(reason)
      }
    }
    .task {
      poller?.cancel()
      poller = Task {
        // Capture sshClient up-front: connectionState is `() -> State` and
        // safely callable from this Sendable Task.
        let probe = sshClient.connectionState
        while !Task.isCancelled {
          let next = probe()
          await MainActor.run { state = next }
          try? await Task.sleep(for: .seconds(4))
        }
      }
    }
    .onDisappear { poller?.cancel() }
  }

  @ViewBuilder
  private func chip(color: Color, label: String, icon: String) -> some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
      Text(label)
        .font(.caption.weight(.medium))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(color.opacity(0.18))
    .foregroundStyle(color)
    .clipShape(Capsule())
  }
}
