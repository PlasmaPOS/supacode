import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteHostTests {
  @Test func sshTargetCombinesUserAndHostname() {
    let host = RemoteHost(user: "shlomo", hostname: "mini.tailnet")
    #expect(host.sshTarget == "shlomo@mini.tailnet")
  }

  @Test func equalityIgnoresDisplayName() {
    let a = RemoteHost(user: "shlomo", hostname: "mini.tailnet", displayName: "Mac Mini")
    let b = RemoteHost(user: "shlomo", hostname: "mini.tailnet", displayName: "Home Box")
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
  }

  @Test func equalityCaresAboutHostname() {
    let a = RemoteHost(user: "shlomo", hostname: "mini.tailnet")
    let b = RemoteHost(user: "shlomo", hostname: "other.tailnet")
    #expect(a != b)
  }

  @Test func equalityCaresAboutReposBaseDir() {
    let a = RemoteHost(user: "shlomo", hostname: "mini", reposBaseDir: "~/.supacode/repos")
    let b = RemoteHost(user: "shlomo", hostname: "mini", reposBaseDir: "/opt/repos")
    #expect(a != b)
  }

  @Test func defaultsArePopulated() {
    let host = RemoteHost(user: "u", hostname: "h")
    #expect(host.port == 22)
    #expect(host.identityFile == nil)
    #expect(host.reposBaseDir == "~/.supacode/repos")
  }

  @Test func codableRoundTrip() throws {
    let original = RemoteHost(
      user: "shlomo",
      hostname: "mini.tailnet",
      port: 2222,
      identityFile: "~/.ssh/id_ed25519",
      reposBaseDir: "/srv/repos",
      displayName: "Mac Mini"
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RemoteHost.self, from: encoded)
    #expect(decoded == original)
    #expect(decoded.displayName == original.displayName)  // displayName preserved through Codable even though == ignores it
  }
}

@MainActor
struct SSHExecResultTests {
  @Test func succeededIsTrueForExitZero() {
    let r = SSHClient.ExecResult(stdout: Data(), stderr: Data(), exitCode: 0)
    #expect(r.succeeded)
  }

  @Test func succeededIsFalseForNonZeroExit() {
    let r = SSHClient.ExecResult(stdout: Data(), stderr: Data(), exitCode: 1)
    #expect(!r.succeeded)
  }

  @Test func stdoutStringTrimsTrailingNewlines() {
    let r = SSHClient.ExecResult(
      stdout: Data("hello\n\n".utf8),
      stderr: Data(),
      exitCode: 0
    )
    #expect(r.stdoutString() == "hello")
  }

  @Test func stdoutStringPreservesInternalNewlines() {
    let r = SSHClient.ExecResult(
      stdout: Data("line1\nline2\n".utf8),
      stderr: Data(),
      exitCode: 0
    )
    #expect(r.stdoutString() == "line1\nline2")
  }

  @Test func stderrStringDoesNotTrim() {
    let r = SSHClient.ExecResult(
      stdout: Data(),
      stderr: Data("oops\n".utf8),
      exitCode: 1
    )
    #expect(r.stderrString() == "oops\n")
  }

  @Test func nonUtf8StdoutFallsBackToEmpty() {
    // 0xFF is not valid UTF-8.
    let r = SSHClient.ExecResult(
      stdout: Data([0xFF]),
      stderr: Data(),
      exitCode: 0
    )
    #expect(r.stdoutString() == "")
  }
}

@MainActor
struct SSHClientUnconfiguredTests {
  @Test func execThrowsNotConfigured() async {
    let client = SSHClient.unconfigured
    await #expect(throws: RemoteError.notConfigured) {
      try await client.exec(["git", "--version"], nil)
    }
  }

  @Test func readFileThrowsNotConfigured() async {
    let client = SSHClient.unconfigured
    await #expect(throws: RemoteError.notConfigured) {
      try await client.readFile("/etc/hosts", false)
    }
  }

  @Test func writeFileThrowsNotConfigured() async {
    let client = SSHClient.unconfigured
    await #expect(throws: RemoteError.notConfigured) {
      try await client.writeFile("/tmp/x", Data())
    }
  }

  @Test func streamThrowsNotConfigured() async {
    let client = SSHClient.unconfigured
    var threw = false
    do {
      for try await _ in client.stream(["ls"]) {
        // No values should arrive — the stream finishes with an error.
      }
    } catch RemoteError.notConfigured {
      threw = true
    } catch {
      Issue.record("Expected RemoteError.notConfigured, got \(error)")
    }
    #expect(threw)
  }

  @Test func connectionStateIsUnconfigured() {
    let client = SSHClient.unconfigured
    #expect(client.connectionState() == .unconfigured)
  }

  @Test func invalidateCacheIsSafeToCall() {
    let client = SSHClient.unconfigured
    client.invalidateCache()  // must not crash
  }

  @Test func watchFinishesImmediately() async {
    let client = SSHClient.unconfigured
    var count = 0
    for await _ in client.watch("/tmp") {
      count += 1
    }
    #expect(count == 0)
  }

  @Test func buildPTYCommandReturnsNilWhenUnconfigured() {
    let client = SSHClient.unconfigured
    #expect(client.buildPTYCommand("ls -la") == nil)
  }
}

@MainActor
struct SSHClientBuildPTYCommandTests {
  @Test func livePTYCommandContainsSSHTargetAndRemoteCommand() {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-ptycmd-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let host = RemoteHost(user: "shlomo", hostname: "mini.test", port: 22)
    let client = SSHClient.live(host: host, controlDirectory: tempDir)
    let cmd = client.buildPTYCommand("echo hi")

    #expect(cmd != nil)
    let unwrapped = cmd ?? ""
    #expect(unwrapped.contains("/usr/bin/ssh"))
    #expect(unwrapped.contains("shlomo@mini.test"))
    #expect(unwrapped.contains("echo hi"))
    #expect(unwrapped.contains("sh"))
    #expect(unwrapped.contains("-c"))
    #expect(unwrapped.contains("-t"))  // PTY allocation
  }

  @Test func livePTYCommandHonorsCustomPort() {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-ptycmd-port-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let host = RemoteHost(user: "u", hostname: "h", port: 2222)
    let client = SSHClient.live(host: host, controlDirectory: tempDir)
    let cmd = client.buildPTYCommand("ls") ?? ""
    #expect(cmd.contains("2222"))
  }

  @Test func livePTYCommandEscapesQuotesInRemoteCommand() {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-ptycmd-quote-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let host = RemoteHost(user: "u", hostname: "h")
    let client = SSHClient.live(host: host, controlDirectory: tempDir)
    // A remote command containing a single quote — POSIX nested-quote escape
    // must turn it into '\'' so the wrapper string round-trips correctly.
    let cmd = client.buildPTYCommand("echo 'hi'") ?? ""
    // The literal `'\\''` POSIX-escape sequence must appear in the command.
    #expect(cmd.contains("'\\''"), "Expected nested-quote escape but got: \(cmd)")
  }
}

@MainActor
struct SSHClientLiveSetupTests {
  /// Verifies that constructing the live client writes a valid ssh config
  /// file in the given control directory. Doesn't dial the network.
  @Test func liveInitWritesSSHConfig() throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-ssh-test-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)

    let host = RemoteHost(user: "shlomo", hostname: "mini.tailnet", port: 22)
    _ = SSHClient.live(host: host, controlDirectory: tempDir)

    let configURL = tempDir.appending(path: "config-mini.tailnet", directoryHint: .notDirectory)
    #expect(FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)))

    let body = try String(contentsOf: configURL, encoding: .utf8)
    #expect(body.contains("Host mini.tailnet"))
    #expect(body.contains("User shlomo"))
    #expect(body.contains("ControlMaster auto"))
    #expect(body.contains("ControlPersist 10m"))

    try? FileManager.default.removeItem(at: tempDir)
  }

  @Test func liveInitDoesNotOverwriteExistingSSHConfig() throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-ssh-test-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let configURL = tempDir.appending(path: "config-mini.tailnet", directoryHint: .notDirectory)
    let userMarker = "# user-modified — do not touch\n"
    try userMarker.data(using: .utf8)!.write(to: configURL)

    let host = RemoteHost(user: "shlomo", hostname: "mini.tailnet")
    _ = SSHClient.live(host: host, controlDirectory: tempDir)

    let body = try String(contentsOf: configURL, encoding: .utf8)
    #expect(body == userMarker, "live() must not overwrite an existing config file")

    try? FileManager.default.removeItem(at: tempDir)
  }
}
