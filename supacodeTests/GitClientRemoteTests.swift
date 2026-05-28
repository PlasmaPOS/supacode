import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteWtRunnerWorktreesTests {
  @Test func parsesWtJsonIntoWorktrees() async throws {
    let repoRoot = URL(fileURLWithPath: "/Users/shlomo/repos/pile")
    let json = """
      [
        {"branch":"main","path":"/Users/shlomo/repos/pile","head":"abc","is_bare":false},
        {"branch":"fix/auth","path":"/Users/shlomo/repos/pile-fix-auth","head":"def","is_bare":false}
      ]
      """
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { argv, _ in
        // The runner wraps everything in `sh -c "cd … && wt ls --json"`.
        #expect(argv == ["sh", "-c", "cd '/Users/shlomo/repos/pile' && '~/.local/bin/wt' 'ls' '--json'"])
        return .ok(stdout: json)
      },
      wtPath: "~/.local/bin/wt"
    )
    let result = try await runner.worktrees(for: repoRoot)
    #expect(result.count == 2)
    #expect(result[0].name == "main")
    #expect(result[0].workingDirectory.path == "/Users/shlomo/repos/pile")
    #expect(result[1].name == "fix/auth")
    #expect(result[1].isAttached)
  }

  @Test func filtersOutBareEntries() async throws {
    let json = """
      [
        {"branch":"","path":"/srv/repos/pile.git","head":"","is_bare":true},
        {"branch":"main","path":"/srv/repos/pile","head":"abc","is_bare":false}
      ]
      """
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in .ok(stdout: json) },
      wtPath: "/usr/local/bin/wt"
    )
    let result = try await runner.worktrees(for: URL(fileURLWithPath: "/srv/repos/pile"))
    #expect(result.count == 1)
    #expect(result[0].name == "main")
  }

  @Test func detachedHeadShowsAsLastPathComponent() async throws {
    let json = """
      [{"branch":"","path":"/Users/shlomo/repos/pile-detached","head":"abc","is_bare":false}]
      """
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in .ok(stdout: json) },
      wtPath: "wt"
    )
    let result = try await runner.worktrees(for: URL(fileURLWithPath: "/Users/shlomo/repos/pile"))
    #expect(result.count == 1)
    #expect(result[0].name == "pile-detached")
    #expect(!result[0].isAttached)
  }

  @Test func nonZeroExitThrowsCommandFailed() async {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in
        .err(exitCode: 128, stderr: "fatal: not a git repository")
      },
      wtPath: "wt"
    )
    await #expect(throws: GitClientError.self) {
      try await runner.worktrees(for: URL(fileURLWithPath: "/tmp/nope"))
    }
  }
}

@MainActor
struct RemoteWtRunnerSimpleOpsTests {
  @Test func repoRootTrimsAndReturnsURL() async throws {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { argv, _ in
        let expected = "cd '/Users/shlomo/repos/pile/subdir' && 'wt' 'root'"
        #expect(argv == ["sh", "-c", expected])
        return .ok(stdout: "/Users/shlomo/repos/pile\n")
      },
      wtPath: "wt"
    )
    let result = try await runner.repoRoot(for: URL(fileURLWithPath: "/Users/shlomo/repos/pile/subdir"))
    #expect(result.path == "/Users/shlomo/repos/pile")
  }

  @Test func repoRootEmptyOutputThrows() async {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in .ok(stdout: "  \n  ") },
      wtPath: "wt"
    )
    await #expect(throws: GitClientError.self) {
      try await runner.repoRoot(for: URL(fileURLWithPath: "/tmp"))
    }
  }

  @Test func isGitRepositoryReturnsTrueOnSuccess() async {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in .ok(stdout: "") },
      wtPath: "wt"
    )
    #expect(await runner.isGitRepository(at: URL(fileURLWithPath: "/repo")))
  }

  @Test func isGitRepositoryReturnsFalseOnError() async {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in .err(exitCode: 1, stderr: "no such file") },
      wtPath: "wt"
    )
    #expect(!(await runner.isGitRepository(at: URL(fileURLWithPath: "/missing"))))
  }

  @Test func directoryExistsTrueOnSuccess() async {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { argv, _ in
        #expect(argv == ["test", "-d", "/srv/repos/pile"])
        return .ok(stdout: "")
      },
      wtPath: "wt"
    )
    #expect(await runner.directoryExists(at: URL(fileURLWithPath: "/srv/repos/pile")))
  }

  @Test func branchNameReturnsTrimmedString() async {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in .ok(stdout: "fix/auth-bug\n") },
      wtPath: "wt"
    )
    let name = await runner.branchName(at: URL(fileURLWithPath: "/repo/wt"))
    #expect(name == "fix/auth-bug")
  }

  @Test func branchNameReturnsNilOnEmpty() async {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in .ok(stdout: "\n") },
      wtPath: "wt"
    )
    #expect(await runner.branchName(at: URL(fileURLWithPath: "/repo/wt")) == nil)
  }

  @Test func branchNameReturnsNilOnSSHError() async {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in .err(exitCode: 1, stderr: "not a worktree") },
      wtPath: "wt"
    )
    #expect(await runner.branchName(at: URL(fileURLWithPath: "/no/such")) == nil)
  }

  @Test func localBranchNamesParsesLineSeparated() async throws {
    let runner = RemoteWtRunner(
      sshClient: .fakeExec { _, _ in
        .ok(stdout: "main\nfix/auth\nfeat/x\n  \n")  // trailing whitespace + blank
      },
      wtPath: "wt"
    )
    let names = try await runner.localBranchNames(for: URL(fileURLWithPath: "/repo"))
    #expect(names == Set(["main", "fix/auth", "feat/x"]))
  }
}

@MainActor
struct RemoteWtRunnerRelativePathTests {
  @Test func sameDirReturnsEmpty() {
    let base = URL(fileURLWithPath: "/repo")
    let target = URL(fileURLWithPath: "/repo")
    #expect(RemoteWtRunner.relativePath(from: base, to: target) == "")
  }

  @Test func childUnderBase() {
    let base = URL(fileURLWithPath: "/repo")
    let target = URL(fileURLWithPath: "/repo/wt/auth")
    #expect(RemoteWtRunner.relativePath(from: base, to: target) == "wt/auth")
  }

  @Test func siblingProducesDotDot() {
    let base = URL(fileURLWithPath: "/repo/sibling")
    let target = URL(fileURLWithPath: "/repo/wt/auth")
    #expect(RemoteWtRunner.relativePath(from: base, to: target) == "../wt/auth")
  }

  @Test func unrelatedTreesUseAllDotDot() {
    let base = URL(fileURLWithPath: "/a/b/c")
    let target = URL(fileURLWithPath: "/x/y")
    #expect(RemoteWtRunner.relativePath(from: base, to: target) == "../../../x/y")
  }
}

@MainActor
struct GitClientDependencyRemoteFactoryTests {
  @Test func factoryWiresPhaseAClosuresWithRunner() async {
    var calls: [String] = []
    let collector = LockIsolated<[String]>([])
    let client = GitClientDependency.remote(
      sshClient: .fakeExec { argv, _ in
        collector.withValue { $0.append(argv.joined(separator: " ")) }
        return .ok(stdout: "/some/path")
      }
    )
    _ = try? await client.repoRoot(URL(fileURLWithPath: "/x"))
    calls = collector.value
    #expect(calls.count == 1)
    #expect(calls[0].contains("wt"))
    #expect(calls[0].contains("root"))
  }

  @Test func phaseBClosuresThrowNotConfigured() async {
    let client = GitClientDependency.remote(sshClient: .unconfigured)
    await #expect(throws: RemoteError.notConfigured) {
      try await client.renameBranch("old", "new", URL(fileURLWithPath: "/x"))
    }
    await #expect(throws: RemoteError.notConfigured) {
      try await client.fetchRemote("origin", URL(fileURLWithPath: "/x"))
    }
    await #expect(throws: RemoteError.notConfigured) {
      try await client.isBareRepository(URL(fileURLWithPath: "/x"))
    }
  }

  @Test func phaseBNonThrowingClosuresReturnSafeDefaults() async {
    let client = GitClientDependency.remote(sshClient: .unconfigured)
    let inv = await client.isValidBranchName("main", URL(fileURLWithPath: "/x"))
    #expect(!inv)
    let baseRef = await client.automaticWorktreeBaseRef(URL(fileURLWithPath: "/x"))
    #expect(baseRef == nil)
    let lc = await client.lineChanges(URL(fileURLWithPath: "/x"))
    #expect(lc == nil)
    let ri = await client.remoteInfo(URL(fileURLWithPath: "/x"))
    #expect(ri == nil)
  }
}

// MARK: - Test helper — fake SSHClient

extension SSHClient {
  /// Build a SSHClient whose `exec` invokes a custom handler. Other surface
  /// (stream/readFile/writeFile/watch/connectionState/buildPTYCommand/etc.)
  /// throws or returns sensible no-ops, matching `.unconfigured`'s shape.
  /// Sufficient for unit tests of clients that only ever call `exec`.
  nonisolated static func fakeExec(
    _ handler: @Sendable @escaping (_ argv: [String], _ timeout: Duration?) async throws -> ExecResult
  ) -> SSHClient {
    SSHClient(
      exec: handler,
      stream: { _ in
        AsyncThrowingStream { $0.finish(throwing: RemoteError.notConfigured) }
      },
      readFile: { _, _ in throw RemoteError.notConfigured },
      writeFile: { _, _ in throw RemoteError.notConfigured },
      watch: { _ in AsyncStream { $0.finish() } },
      connectionState: { .connected },
      invalidateCache: {},
      buildPTYCommand: { _ in nil }
    )
  }
}

extension SSHClient.ExecResult {
  nonisolated static func ok(stdout: String) -> SSHClient.ExecResult {
    SSHClient.ExecResult(
      stdout: Data(stdout.utf8),
      stderr: Data(),
      exitCode: 0
    )
  }

  nonisolated static func err(exitCode: Int32, stderr: String) -> SSHClient.ExecResult {
    SSHClient.ExecResult(
      stdout: Data(),
      stderr: Data(stderr.utf8),
      exitCode: exitCode
    )
  }
}
