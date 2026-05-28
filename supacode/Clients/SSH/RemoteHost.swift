import Foundation

/// Identity of a remote host that Supacode operates against in remote mode.
///
/// Mirrors the minimal subset of OpenSSH client config Supacode needs to wire
/// `ControlMaster=auto` multiplexing without depending on the user's
/// `~/.ssh/config`. We write our own `~/.ssh/supacode_config` and reference
/// it via `ssh -F`, so user-side config can stay untouched.
///
/// `displayName` is purely for UI; equality / hashing ignores it so the same
/// host with different display labels still de-dupes.
public nonisolated struct RemoteHost: Equatable, Hashable, Codable, Sendable {
  /// SSH user (e.g. `shlomo`).
  public var user: String

  /// Hostname or IP (e.g. `mini.tailnet` or `100.96.166.55`).
  public var hostname: String

  /// SSH port. Defaults to 22.
  public var port: UInt16

  /// Optional explicit identity file (e.g. `~/.ssh/id_ed25519`).
  /// When nil, ssh-agent is used.
  public var identityFile: String?

  /// Base directory on the remote where Supacode-managed repos live. Used as
  /// the default for the "Add Repository" picker and for the bootstrap.
  /// Defaults to `~/.supacode/repos`.
  public var reposBaseDir: String

  /// Free-form label shown in UI ("Mac Mini", "Home Box"). Not part of identity.
  public var displayName: String

  public init(
    user: String,
    hostname: String,
    port: UInt16 = 22,
    identityFile: String? = nil,
    reposBaseDir: String = "~/.supacode/repos",
    displayName: String = ""
  ) {
    self.user = user
    self.hostname = hostname
    self.port = port
    self.identityFile = identityFile
    self.reposBaseDir = reposBaseDir
    self.displayName = displayName
  }

  /// The `user@host` short form used as the SSH connection target.
  nonisolated public var sshTarget: String { "\(user)@\(hostname)" }

  /// Equality / hashing ignore `displayName` — same machine with a different
  /// label should still de-dupe in the host picker.
  public static func == (lhs: RemoteHost, rhs: RemoteHost) -> Bool {
    lhs.user == rhs.user
      && lhs.hostname == rhs.hostname
      && lhs.port == rhs.port
      && lhs.identityFile == rhs.identityFile
      && lhs.reposBaseDir == rhs.reposBaseDir
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(user)
    hasher.combine(hostname)
    hasher.combine(port)
    hasher.combine(identityFile)
    hasher.combine(reposBaseDir)
  }
}
