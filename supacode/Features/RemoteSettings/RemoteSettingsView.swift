import SwiftUI

/// Standalone settings sheet for remote-mode configuration. Lives outside the
/// main `SettingsFeature` panel intentionally — see `RemoteSettingsStore`'s
/// header for why (cross-module type ownership).
///
/// Opened by a menu command (TBD wire in Slice 6 follow-up — `Window > Remote
/// Mode…` or similar). For now this view can be presented as a sheet from
/// anywhere by passing in an `@Binding` to a presented bool + an `onSave`
/// closure that the host can use to refresh state.
///
/// **Persistence flow**: form values are loaded from `RemoteSettingsStore`
/// on appear, written back via `RemoteSettingsStore.save(_:)` on the Save
/// button tap. There is no live "apply" — saving sets a flag and prompts
/// the user to relaunch. This matches the design decision (launch-time
/// mode swap only for v1).
public struct RemoteSettingsView: View {
  @State private var mode: RemoteSettings.Mode
  @State private var user: String
  @State private var hostname: String
  @State private var portText: String
  @State private var identityFile: String
  @State private var reposBaseDir: String
  @State private var displayName: String

  @State private var saveError: String?
  @State private var showRelaunchPrompt = false

  /// Called after a successful save. Hosts can use this to dismiss the sheet
  /// + show a "Restart to apply" toast.
  var onSave: ((RemoteSettings) -> Void)?

  public init(onSave: ((RemoteSettings) -> Void)? = nil) {
    let initial = RemoteSettingsStore.loaded()
    let host = initial.host
    self._mode = State(initialValue: initial.mode)
    self._user = State(initialValue: host?.user ?? NSUserName())
    self._hostname = State(initialValue: host?.hostname ?? "")
    self._portText = State(initialValue: host.map { String($0.port) } ?? "22")
    self._identityFile = State(initialValue: host?.identityFile ?? "")
    self._reposBaseDir = State(initialValue: host?.reposBaseDir ?? "~/.supacode/repos")
    self._displayName = State(initialValue: host?.displayName ?? "")
    self.onSave = onSave
  }

  public var body: some View {
    Form {
      Section("Mode") {
        Picker("Mode", selection: $mode) {
          Text("Local").tag(RemoteSettings.Mode.local)
          Text("Remote").tag(RemoteSettings.Mode.remote)
        }
        .pickerStyle(.segmented)

        Text(
          mode == .remote
            ? "Vortex Code will route all git, gh, terminal, and worktree operations over SSH to the configured remote host. The local machine becomes a thin UI client."
            : "Vortex Code operates against the local filesystem as usual."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if mode == .remote {
        Section("Remote Host") {
          TextField("Display name (optional)", text: $displayName)
            .textFieldStyle(.roundedBorder)

          HStack {
            TextField("User", text: $user)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 140)

            Text("@")
              .foregroundStyle(.secondary)

            TextField("hostname (e.g. mini.tailnet)", text: $hostname)
              .textFieldStyle(.roundedBorder)
          }

          HStack {
            Text("Port")
              .frame(width: 80, alignment: .leading)
            TextField("22", text: $portText)
              .textFieldStyle(.roundedBorder)
              .frame(maxWidth: 80)
          }

          HStack {
            Text("Identity file")
              .frame(width: 80, alignment: .leading)
            TextField("~/.ssh/id_ed25519 (optional)", text: $identityFile)
              .textFieldStyle(.roundedBorder)
          }
        }

        Section("Layout") {
          HStack {
            Text("Repos dir")
              .frame(width: 100, alignment: .leading)
            TextField("~/.supacode/repos", text: $reposBaseDir)
              .textFieldStyle(.roundedBorder)
          }
          Text("Where Supacode-managed worktrees live on the remote. Created on first connect if missing.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Bootstrap") {
          Text(
            "Before saving, run `scripts/remote-bootstrap.sh \(user.isEmpty ? "user" : user)@\(hostname.isEmpty ? "host" : hostname)` to install `wt`, `gh`, and `zmx` on the remote."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        }
      }

      if let saveError {
        Section {
          Label(saveError, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }

      if showRelaunchPrompt {
        Section {
          Label(
            "Saved. Quit and relaunch Supacode for the mode change to take effect.",
            systemImage: "checkmark.circle.fill"
          )
          .foregroundStyle(.green)
        }
      }
    }
    .formStyle(.grouped)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(!canSave)
      }
    }
    .frame(minWidth: 480, minHeight: 360)
  }

  private var canSave: Bool {
    if mode == .local { return true }
    return !user.isEmpty && !hostname.isEmpty && (UInt16(portText) ?? 0) > 0
  }

  private func save() {
    saveError = nil
    let settings: RemoteSettings
    if mode == .local {
      settings = .local
    } else {
      guard let port = UInt16(portText), port > 0 else {
        saveError = "Port must be a number between 1 and 65535."
        return
      }
      let host = RemoteHost(
        user: user,
        hostname: hostname,
        port: port,
        identityFile: identityFile.isEmpty ? nil : identityFile,
        reposBaseDir: reposBaseDir.isEmpty ? "~/.supacode/repos" : reposBaseDir,
        displayName: displayName
      )
      settings = RemoteSettings(mode: .remote, host: host)
    }
    do {
      try RemoteSettingsStore.save(settings)
      showRelaunchPrompt = true
      onSave?(settings)
    } catch {
      saveError = "Failed to save: \(error.localizedDescription)"
    }
  }
}
