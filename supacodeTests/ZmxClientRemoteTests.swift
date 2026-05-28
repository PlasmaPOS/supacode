import Foundation
import Testing

@testable import supacode

@MainActor
struct ZmxRemoteAttachBuildRemoteCommandTests {
  @Test func attachOnlyWhenUserCommandIsNil() {
    let cmd = ZmxRemoteAttach.buildRemoteCommand(
      remoteZmxBinary: "~/.local/bin/zmx",
      remoteSocketDirOption: "",
      sessionID: "supa-abc",
      userCommand: nil
    )
    #expect(cmd == "'~/.local/bin/zmx' attach supa-abc")
  }

  @Test func attachOnlyWhenUserCommandIsBlankOrWhitespace() {
    for blank in ["", "   ", "\n", " \t \n"] {
      let cmd = ZmxRemoteAttach.buildRemoteCommand(
        remoteZmxBinary: "/zmx",
        remoteSocketDirOption: "",
        sessionID: "supa-x",
        userCommand: blank
      )
      #expect(cmd == "'/zmx' attach supa-x", "blank='\(blank)' should produce attach-only")
    }
  }

  @Test func wrapsUserCommandInShc() {
    let cmd = ZmxRemoteAttach.buildRemoteCommand(
      remoteZmxBinary: "/zmx",
      remoteSocketDirOption: "",
      sessionID: "supa-x",
      userCommand: "claude"
    )
    #expect(cmd == "'/zmx' attach supa-x /bin/sh -c 'claude'")
  }

  @Test func escapesSingleQuotesInUserCommand() {
    let cmd = ZmxRemoteAttach.buildRemoteCommand(
      remoteZmxBinary: "/zmx",
      remoteSocketDirOption: "",
      sessionID: "supa-x",
      userCommand: "echo 'hi'"
    )
    #expect(cmd == "'/zmx' attach supa-x /bin/sh -c 'echo '\\''hi'\\'''")
  }

  @Test func prefixesEnvWhenSocketDirOptionGiven() {
    let cmd = ZmxRemoteAttach.buildRemoteCommand(
      remoteZmxBinary: "/zmx",
      remoteSocketDirOption: "ZMX_DIR=/tmp/zmx-501",
      sessionID: "supa-x",
      userCommand: "claude"
    )
    #expect(cmd == "ZMX_DIR=/tmp/zmx-501 '/zmx' attach supa-x /bin/sh -c 'claude'")
  }

  @Test func escapesZmxBinaryPathContainingSpaces() {
    let cmd = ZmxRemoteAttach.buildRemoteCommand(
      remoteZmxBinary: "/Applications/Has Spaces/zmx",
      remoteSocketDirOption: "",
      sessionID: "supa-x",
      userCommand: nil
    )
    #expect(cmd == "'/Applications/Has Spaces/zmx' attach supa-x")
  }
}

@MainActor
struct ZmxRemoteAttachBuildCommandTests {
  /// With `.unconfigured`, buildCommand returns nil — callers can detect
  /// "remote mode broken" without trying to spawn an ssh command that
  /// would silently dial the wrong host.
  @Test func unconfiguredSSHClientReturnsNil() {
    let cmd = ZmxRemoteAttach.buildCommand(
      sshClient: .unconfigured,
      remoteZmxBinary: "/zmx",
      remoteSocketDirOption: "",
      sessionID: "supa-x",
      userCommand: "claude"
    )
    #expect(cmd == nil)
  }

  /// With a live SSHClient (bound to a tempdir control directory so init
  /// doesn't dial the network), buildCommand returns a usable ssh string.
  @Test func liveSSHClientProducesSSHCommand() {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-ssh-cmdbuild-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let host = RemoteHost(user: "shlomo", hostname: "mini.test")
    let sshClient = SSHClient.live(host: host, controlDirectory: tempDir)

    let cmd = ZmxRemoteAttach.buildCommand(
      sshClient: sshClient,
      remoteZmxBinary: "/zmx",
      remoteSocketDirOption: "",
      sessionID: "supa-x",
      userCommand: "claude"
    )
    #expect(cmd != nil)
    let unwrapped = cmd ?? ""
    #expect(unwrapped.contains("/usr/bin/ssh"))
    #expect(unwrapped.contains("shlomo@mini.test"))
    #expect(unwrapped.contains("attach supa-x"))
    #expect(unwrapped.contains("claude"))
  }
}

@MainActor
struct ZmxClientRemoteFactoryTests {
  /// Smoke test for the public surface with a live SSHClient (tempdir-bound
  /// so init doesn't dial the network).
  @Test func remoteFactoryProducesUsableStruct() {
    let (sshClient, tempDir) = makeLiveSSHClient()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let client = ZmxClient.remote(sshClient: sshClient)
    #expect(client.isBundled())
    #expect(client.executableURL() == nil)
    let wrapped = client.wrapCommand("supa-test", "claude")
    #expect(wrapped != nil)
    #expect(wrapped!.contains("attach supa-test"))
    #expect(wrapped!.contains("claude"))
  }

  @Test func remoteWrapCommandWorksWithoutUserCommand() {
    let (sshClient, tempDir) = makeLiveSSHClient()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let client = ZmxClient.remote(sshClient: sshClient)
    let wrapped = client.wrapCommand("supa-x", nil)
    #expect(wrapped != nil)
    #expect(wrapped!.contains("attach supa-x"))
    #expect(!wrapped!.contains("/bin/sh -c"))
  }

  @Test func customZmxBinaryPathIsThreaded() {
    let (sshClient, tempDir) = makeLiveSSHClient()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let client = ZmxClient.remote(
      sshClient: sshClient,
      zmxBinaryPath: "/opt/local/bin/zmx"
    )
    let wrapped = client.wrapCommand("supa-x", "ls")
    #expect(wrapped!.contains("/opt/local/bin/zmx"))
  }

  @Test func customSocketDirIsThreadedAsEnvPrefix() {
    let (sshClient, tempDir) = makeLiveSSHClient()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let client = ZmxClient.remote(
      sshClient: sshClient,
      remoteSocketDir: "/var/run/zmx"
    )
    let wrapped = client.wrapCommand("supa-x", nil)
    #expect(wrapped!.contains("ZMX_DIR=/var/run/zmx"))
  }

  @Test func wrapCommandReturnsNilWhenUnconfigured() {
    let client = ZmxClient.remote(sshClient: .unconfigured)
    // No live SSHClient => buildPTYCommand returns nil => wrapCommand returns nil.
    #expect(client.wrapCommand("supa-x", "claude") == nil)
  }

  /// Build a live SSHClient pointed at a tempdir control directory. The
  /// returned `URL` is the tempdir for the caller to clean up.
  private func makeLiveSSHClient() -> (SSHClient, URL) {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-zmxremote-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    let host = RemoteHost(user: "shlomo", hostname: "mini.test")
    let client = SSHClient.live(host: host, controlDirectory: tempDir)
    return (client, tempDir)
  }
}

@MainActor
struct ZmxClientRemoteListSessionsTests {
  /// `listSessions` parses zmx ls --short output by filtering to the supa-
  /// prefix. Verifying by mocking SSHClient.exec via dependency injection
  /// isn't possible from the test (the factory takes a real SSHClient
  /// value), so we instead verify the structural contract: when SSH is
  /// unconfigured, listSessions returns [] without throwing.
  @Test func listSessionsReturnsEmptyWhenSSHUnconfigured() async {
    let client = ZmxClient.remote(sshClient: .unconfigured)
    let sessions = await client.listSessions()
    #expect(sessions == [])
  }

  @Test func killSessionDoesNotThrowWhenSSHUnconfigured() async {
    let client = ZmxClient.remote(sshClient: .unconfigured)
    // Must complete without throwing — kill paths are deliberately tolerant.
    await client.killSession("supa-nonexistent")
  }
}
