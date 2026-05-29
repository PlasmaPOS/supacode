import ComposableArchitecture
import Dependencies
import Foundation
import SupacodeSettingsShared

/// Uploads a LOCAL file to the remote host over SSH so the user can drag a
/// file onto a Supacode tab and the agent (running on the remote) can read
/// it. Returns the remote path the upload landed at; callers paste that
/// path into the active agent surface.
///
/// Storage location: `/tmp/supacode-uploads/<uuid>-<filename>` by default
/// (tmpfs — wiped on Mini reboot). Override via `remoteUploadsDir` for a
/// persistent location.
///
/// Uses `scp` rather than `SSHClient.writeFile` because (a) `scp` handles
/// arbitrary file sizes natively without our 1 MB read cap, and (b) we
/// preserve the original mtime/permissions — useful for the agent seeing
/// "this was just dropped" via stat.
struct RemoteFileUploadClient: Sendable {
  /// Upload `localURL` to the remote. Returns the absolute remote path
  /// or throws `RemoteError` on failure.
  var upload: @Sendable (_ localURL: URL) async throws -> String
}

extension RemoteFileUploadClient {
  nonisolated static func live(
    sshHost: RemoteHost,
    remoteUploadsDir: String = "/tmp/supacode-uploads"
  ) -> RemoteFileUploadClient {
    RemoteFileUploadClient(
      upload: { localURL in
        let localPath = localURL.path(percentEncoded: false)
        let filename = localURL.lastPathComponent
        let uuid = UUID().uuidString.lowercased()
        let remotePath = "\(remoteUploadsDir)/\(uuid)-\(filename)"

        // Ensure the uploads dir exists. Cheap; runs once per upload.
        try await sshMkdir(host: sshHost, path: remoteUploadsDir)

        // scp the file. Single command, no shell, no quoting nightmares.
        try await scpUpload(host: sshHost, localPath: localPath, remotePath: remotePath)

        return remotePath
      }
    )
  }

  /// Unconfigured variant — throws on every upload so the UI fails loud
  /// instead of silently dropping the file.
  nonisolated static let unconfigured = RemoteFileUploadClient(
    upload: { _ in throw RemoteError.notConfigured }
  )
}

extension RemoteFileUploadClient: DependencyKey {
  nonisolated static let liveValue: RemoteFileUploadClient = .unconfigured
  nonisolated static let testValue: RemoteFileUploadClient = .unconfigured
}

extension DependencyValues {
  nonisolated var remoteFileUploadClient: RemoteFileUploadClient {
    get { self[RemoteFileUploadClient.self] }
    set { self[RemoteFileUploadClient.self] = newValue }
  }
}

// MARK: - SSH/SCP plumbing

nonisolated private func sshMkdir(host: RemoteHost, path: String) async throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
  process.arguments = ["-o", "BatchMode=yes", "-p", "\(host.port)", host.sshTarget, "--", "mkdir", "-p", path]
  try await runProcessExpectingSuccess(process, label: "ssh mkdir")
}

nonisolated private func scpUpload(
  host: RemoteHost,
  localPath: String,
  remotePath: String
) async throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
  process.arguments = [
    "-o", "BatchMode=yes",
    "-P", "\(host.port)",
    "-p",  // preserve mtime + permissions
    localPath,
    "\(host.sshTarget):\(remotePath)",
  ]
  try await runProcessExpectingSuccess(process, label: "scp")
}

nonisolated private func runProcessExpectingSuccess(
  _ process: Process,
  label: String
) async throws {
  let stderrPipe = Pipe()
  process.standardError = stderrPipe
  process.standardOutput = FileHandle.nullDevice

  let exitStream = AsyncStream<Int32> { continuation in
    process.terminationHandler = { proc in
      continuation.yield(proc.terminationStatus)
      continuation.finish()
    }
  }

  do {
    try process.run()
  } catch {
    throw RemoteError.spawnFailed(underlying: "\(label): \(error)")
  }

  // 60s upload timeout — enough for ~100 MB on a typical Tailscale link.
  let exitStatus = await withTaskGroup(of: Int32?.self) { group -> Int32? in
    group.addTask {
      for await status in exitStream { return status }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(60))
      return nil
    }
    defer { group.cancelAll() }
    return await group.next() ?? nil
  }

  guard let exitStatus else {
    if process.isRunning { process.terminate() }
    throw RemoteError.timeout(after: .seconds(60))
  }

  if exitStatus != 0 {
    let stderr =
      (try? stderrPipe.fileHandleForReading.readToEnd())
      .flatMap { String(data: $0 ?? Data(), encoding: .utf8) } ?? ""
    throw RemoteError.remoteCommandFailed(exitCode: exitStatus, stderr: stderr)
  }
}
