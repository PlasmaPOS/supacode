import SwiftUI

/// Menu item under `Supacode > Remote Mode…` that opens the standalone
/// `RemoteSettingsView` window. Lives as a separate `View` because
/// `openWindow` is only available through `@Environment` inside a View
/// — can't be called from inside a `CommandGroup`'s closure directly.
struct RemoteModeMenuButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Remote Mode…") {
      openWindow(id: WindowID.remoteSettings)
    }
    .help("Configure SSH host for remote mode (sessions live on the remote)")
  }
}
