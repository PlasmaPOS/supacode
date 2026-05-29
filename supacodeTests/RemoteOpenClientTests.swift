import Foundation
import Testing

@testable import supacode

/// Tests for the pure URL/quote helpers in RemoteOpenClient. The live SSH
/// path can't be exercised in unit tests (needs a real host), but the URL
/// construction has enough edge cases that it earns its own coverage —
/// VS Code's Remote-SSH URL scheme is finicky.
@Suite("RemoteOpenClient pure helpers")
struct RemoteOpenClientTests {
  @Test("VS Code URL escapes absolute path correctly")
  func vscodeURLForAbsolutePath() {
    let url = RemoteOpenClient.vscodeRemoteSSHURL(
      sshTarget: "shlomo@mini.tailnet",
      path: "/Users/shlomo/repos/vortex/README.md"
    )
    // `@` percent-encodes to `%40` under .urlHostAllowed (RFC 3986: `@` is
    // the userinfo/host separator). VS Code's URL decoder handles either
    // form correctly; we just verify what the spec-compliant output is.
    #expect(url == "vscode://vscode-remote/ssh-remote+shlomo%40mini.tailnet/Users/shlomo/repos/vortex/README.md")
  }

  @Test("VS Code URL prepends slash when path is relative")
  func vscodeURLAddsLeadingSlash() {
    let url = RemoteOpenClient.vscodeRemoteSSHURL(
      sshTarget: "shlomo@mini",
      path: "repos/vortex"
    )
    #expect(url.hasPrefix("vscode://vscode-remote/ssh-remote+shlomo%40mini/"))
    #expect(url.hasSuffix("/repos/vortex"))
  }

  @Test("VS Code URL handles paths with spaces")
  func vscodeURLEscapesSpaces() {
    let url = RemoteOpenClient.vscodeRemoteSSHURL(
      sshTarget: "user@host",
      path: "/tmp/with space/file.txt"
    )
    // Spaces must be percent-encoded for URL(string:) to accept the result.
    #expect(URL(string: url) != nil)
    #expect(url.contains("%20"))
  }

  @Test("shellQuote wraps simple paths in single quotes")
  func shellQuoteSimple() {
    let quoted = RemoteOpenClient.shellQuote("/tmp/foo")
    #expect(quoted == "'/tmp/foo'")
  }

  @Test("shellQuote escapes embedded single quotes")
  func shellQuoteEscapesQuotes() {
    let quoted = RemoteOpenClient.shellQuote("/tmp/o'brien.txt")
    // Standard POSIX trick: ' → '\''. Final string: '/tmp/o'\''brien.txt'
    #expect(quoted == "'/tmp/o'\\''brien.txt'")
  }

  @Test("shellQuote handles empty string safely")
  func shellQuoteEmpty() {
    let quoted = RemoteOpenClient.shellQuote("")
    #expect(quoted == "''")
  }
}
