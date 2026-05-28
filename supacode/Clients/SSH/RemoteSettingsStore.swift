import Foundation
import SupacodeSettingsShared

/// Persistence + retrieval of the user's remote-mode configuration.
///
/// Stored as a small JSON file at `~/.supacode/remote.json` (created on first
/// save). Separate from `GlobalSettings` on purpose — that lives in
/// `SupacodeSettingsShared` and can't reference `RemoteHost` (which lives in
/// `supacode`) without a cross-module refactor. A standalone file is also a
/// natural fit: remote config is launch-time-only (no live hot-swap per the
/// design doc), so it's read once at app startup and written by the settings
/// sheet at user save-time.
///
/// **Schema v1** (matches `RemoteHost` 1:1):
/// ```json
/// {
///   "mode": "remote" | "local",
///   "host": { ...RemoteHost fields... }
/// }
/// ```
///
/// On a fresh install or a missing file, `loaded()` returns
/// `RemoteSettings(mode: .local, host: nil)` — the app stays in local mode
/// until the user explicitly switches.
public nonisolated struct RemoteSettings: Codable, Equatable, Sendable {
  public enum Mode: String, Codable, Equatable, Sendable {
    case local
    case remote
  }

  public var mode: Mode
  public var host: RemoteHost?

  public init(mode: Mode = .local, host: RemoteHost? = nil) {
    self.mode = mode
    self.host = host
  }

  public static let local = RemoteSettings(mode: .local, host: nil)
}

nonisolated public enum RemoteSettingsStore {
  /// Default config file location. Tests inject an override via the
  /// `at:` parameter on `loaded(at:)` / `save(_:to:)`.
  public static var defaultLocation: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".supacode/remote.json", directoryHint: .notDirectory)
  }

  /// Load the persisted remote settings. Returns `.local` when the file is
  /// missing or malformed (logged + fallthrough — never throws to caller).
  public static func loaded(at url: URL = defaultLocation) -> RemoteSettings {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return .local
    }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode(RemoteSettings.self, from: data)
    } catch {
      // Don't lose the user's config on a parse error — fall back to local
      // mode but keep the broken file intact so a future debugger can see it.
      remoteSettingsLogger.warning("Failed to decode \(url.path(percentEncoded: false)): \(error)")
      return .local
    }
  }

  /// Persist the remote settings atomically. Creates the parent directory if
  /// missing. Throws on I/O failure so the settings UI can surface the
  /// error to the user.
  public static func save(_ settings: RemoteSettings, to url: URL = defaultLocation) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(settings)
    try data.write(to: url, options: .atomic)
  }

  /// Clear the persisted settings — swaps the app back to local mode on
  /// next launch.
  public static func clear(at url: URL = defaultLocation) throws {
    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      try FileManager.default.removeItem(at: url)
    }
  }
}

nonisolated private let remoteSettingsLogger = SupaLogger("RemoteSettings")
