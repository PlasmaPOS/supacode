import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteSettingsStoreTests {
  private func tempFile() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "remote-settings-\(UUID().uuidString.lowercased()).json", directoryHint: .notDirectory)
  }

  @Test func loadedReturnsLocalForMissingFile() {
    let path = tempFile()
    let s = RemoteSettingsStore.loaded(at: path)
    #expect(s == .local)
    #expect(s.mode == .local)
    #expect(s.host == nil)
  }

  @Test func saveAndLoadRoundTripsLocalMode() throws {
    let path = tempFile()
    defer { try? FileManager.default.removeItem(at: path) }
    try RemoteSettingsStore.save(.local, to: path)
    let loaded = RemoteSettingsStore.loaded(at: path)
    #expect(loaded == .local)
  }

  @Test func saveAndLoadRoundTripsRemoteMode() throws {
    let path = tempFile()
    defer { try? FileManager.default.removeItem(at: path) }
    let host = RemoteHost(
      user: "shlomo",
      hostname: "mini.tailnet",
      port: 2222,
      identityFile: "~/.ssh/id_ed25519",
      reposBaseDir: "/srv/repos",
      displayName: "Mac Mini"
    )
    let original = RemoteSettings(mode: .remote, host: host)
    try RemoteSettingsStore.save(original, to: path)
    let loaded = RemoteSettingsStore.loaded(at: path)
    #expect(loaded == original)
    #expect(loaded.host?.user == "shlomo")
    #expect(loaded.host?.port == 2222)
  }

  @Test func saveCreatesMissingParentDirectory() throws {
    let nested = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "supacode-rs-\(UUID().uuidString.lowercased())/inner/remote.json", directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: nested.deletingLastPathComponent().deletingLastPathComponent()) }

    try RemoteSettingsStore.save(.local, to: nested)
    #expect(FileManager.default.fileExists(atPath: nested.path(percentEncoded: false)))
  }

  @Test func loadedFallsBackToLocalOnCorruptFile() throws {
    let path = tempFile()
    defer { try? FileManager.default.removeItem(at: path) }
    try "not json {".data(using: .utf8)!.write(to: path)
    let loaded = RemoteSettingsStore.loaded(at: path)
    #expect(loaded == .local)
  }

  @Test func clearRemovesFile() throws {
    let path = tempFile()
    try RemoteSettingsStore.save(.local, to: path)
    #expect(FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
    try RemoteSettingsStore.clear(at: path)
    #expect(!FileManager.default.fileExists(atPath: path.path(percentEncoded: false)))
  }

  @Test func clearIsIdempotentForMissingFile() throws {
    let path = tempFile()
    // Must not throw when the file doesn't exist.
    try RemoteSettingsStore.clear(at: path)
  }
}
