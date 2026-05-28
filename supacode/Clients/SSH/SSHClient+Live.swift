import ComposableArchitecture
import Dependencies
import Foundation
import SupacodeSettingsShared

// Local logger for the LiveRuntime — `sshLogger` in SSHClient.swift is
// `private`, so we declare a separate instance scoped to this file.
nonisolated private let sshLogger = SupaLogger("SSH.Live")

extension SSHClient {
  /// Build the live `SSHClient` bound to a specific `RemoteHost`. Call this
  /// at app startup once the persisted remote-mode config is loaded; inject
  /// the result by overriding `sshClient` in the root `DependencyValues`.
  ///
  /// `controlDirectory` is where we keep the ControlMaster socket + our
  /// custom ssh config. Defaults to `~/.supacode/ssh/` (created on demand).
  /// Tests inject a tempdir.
  ///
  /// We don't validate reachability here — that's `connectionState`'s job.
  /// Construction is cheap and never blocks the caller.
  nonisolated static func live(
    host: RemoteHost,
    controlDirectory overrideControlDir: URL? = nil
  ) -> SSHClient {
    let runtime = LiveRuntime(host: host, controlDirectory: overrideControlDir)

    return SSHClient(
      exec: { argv, timeout in
        try await runtime.exec(argv: argv, timeout: timeout ?? defaultExecTimeout)
      },
      stream: { argv in
        // Slice 1 ships a stub. Slice 4 (Remote WorktreeInfoWatcher) wires
        // this up to a real long-lived `Process` whose stdout pipe emits one
        // line per yielded value. Keeping the surface honest now means
        // callers can already write against it.
        AsyncThrowingStream { continuation in
          continuation.finish(throwing: RemoteError.spawnFailed(
            underlying: "SSHClient.stream is stubbed in Slice 1 (see Remote Mode design doc)"
          ))
        }
      },
      readFile: { path, bypassCache in
        try await runtime.readFile(path: path, bypassCache: bypassCache)
      },
      writeFile: { path, data in
        try await runtime.writeFile(path: path, data: data)
      },
      watch: { _ in
        // Slice 4. See `stream` comment.
        AsyncStream { $0.finish() }
      },
      connectionState: {
        runtime.currentConnectionState()
      },
      invalidateCache: {
        runtime.invalidateReadCache()
      },
      buildPTYCommand: { remoteCommand in
        runtime.buildPTYCommand(remoteCommand: remoteCommand)
      }
    )
  }
}

// MARK: - LiveRuntime

/// Shared state behind the live `SSHClient` closures. Owns:
/// - the per-host ssh config file we write
/// - the in-process `readFile` cache
/// - the latest known `ConnectionState`
///
/// `nonisolated` throughout — the SSHClient struct's `@Sendable` closures call
/// these methods from any executor, and none of them touch main-actor state.
private final class LiveRuntime: @unchecked Sendable {
  nonisolated private let host: RemoteHost
  nonisolated private let controlDirectory: URL
  nonisolated private let sshConfigPath: URL
  nonisolated private let controlSocketTemplate: String
  nonisolated private let readCache = LockIsolated<[String: CacheEntry]>([:])
  nonisolated private let connectionStateBox = LockIsolated<SSHClient.ConnectionState>(.reconnecting)

  nonisolated init(host: RemoteHost, controlDirectory overrideControlDir: URL?) {
    self.host = host
    if let overrideControlDir {
      self.controlDirectory = overrideControlDir
    } else {
      self.controlDirectory = LiveRuntime.defaultControlDirectory()
    }
    // Per-host config so a future multi-host launch never mixes ControlMaster
    // sockets across machines.
    self.sshConfigPath = self.controlDirectory.appending(
      path: "config-\(host.hostname.sanitizedForFilename())",
      directoryHint: .notDirectory
    )
    // `%C` is OpenSSH's per-connection hash placeholder — gives us short,
    // collision-free socket names under the macOS sun_path budget.
    self.controlSocketTemplate = self.controlDirectory
      .appending(path: "ctl-%C", directoryHint: .notDirectory)
      .path(percentEncoded: false)

    do {
      try ensureControlDirectoryExists()
      try writeSSHConfigIfNeeded()
    } catch {
      // Don't crash — fail commands lazily with a clear error.
      sshLogger.warning("LiveRuntime init: failed to prepare ssh config: \(error)")
      connectionStateBox.setValue(.offline(reason: "Couldn't write ssh config: \(error)"))
    }
  }

  // MARK: exec

  nonisolated func exec(argv: [String], timeout: Duration) async throws -> SSHClient.ExecResult {
    guard !argv.isEmpty else {
      throw RemoteError.spawnFailed(underlying: "exec called with empty argv")
    }
    let sshArgs = baseSSHArgs() + [host.sshTarget, "--"] + argv.map(shellQuote)
    return try await runSSH(arguments: sshArgs, timeout: timeout)
  }

  // MARK: readFile

  nonisolated func readFile(path: String, bypassCache: Bool) async throws -> Data {
    if !bypassCache, let cached = readCache.withValue({ $0[path] }), !cached.isStale {
      return cached.data
    }
    // `wc -c` first to size-check; then `cat` to fetch. Two round trips, but
    // both multiplex over the existing ControlMaster so the overhead is
    // minimal (~5ms each over Tailscale-local Mini).
    let size = try await fileSize(path: path)
    guard size <= SSHClient.readFileMaxBytes else {
      throw RemoteError.fileTooLarge(bytes: size)
    }
    let result = try await exec(argv: ["cat", "--", path], timeout: SSHClient.defaultExecTimeout)
    guard result.succeeded else {
      throw RemoteError.remoteCommandFailed(
        exitCode: result.exitCode,
        stderr: result.stderrString()
      )
    }
    readCache.withValue { $0[path] = CacheEntry(data: result.stdout, fetchedAt: .now) }
    return result.stdout
  }

  /// Bytes via `wc -c < path` (avoids stat's variable output formats across
  /// macOS / Linux).
  nonisolated private func fileSize(path: String) async throws -> Int {
    let result = try await exec(
      argv: ["sh", "-c", "wc -c < \(shellQuote(path))"],
      timeout: .seconds(5)
    )
    guard result.succeeded else {
      throw RemoteError.remoteCommandFailed(
        exitCode: result.exitCode,
        stderr: result.stderrString()
      )
    }
    let trimmed = result.stdoutString().trimmingCharacters(in: .whitespaces)
    guard let bytes = Int(trimmed) else {
      throw RemoteError.spawnFailed(underlying: "wc -c output not parseable: \(trimmed)")
    }
    return bytes
  }

  // MARK: writeFile

  /// Atomic write: stream `data` into `<path>.tmp.<uuid>` via stdin → `mv`
  /// the temp file over `path`. Observers never see a partial file.
  nonisolated func writeFile(path: String, data: Data) async throws {
    let tempPath = "\(path).tmp.\(UUID().uuidString.lowercased())"
    // `cat > <tempPath>` is the smallest portable upload primitive. For files
    // beyond `readFileMaxBytes` we'd want scp/rsync, but Slice 1 only needs
    // the small-file path.
    guard data.count <= SSHClient.readFileMaxBytes else {
      throw RemoteError.fileTooLarge(bytes: data.count)
    }
    let sshArgs = baseSSHArgs() + [
      host.sshTarget,
      "--",
      "sh", "-c", shellQuote("cat > \(shellQuote(tempPath)) && mv \(shellQuote(tempPath)) \(shellQuote(path))"),
    ]
    let result = try await runSSH(arguments: sshArgs, timeout: SSHClient.defaultExecTimeout, stdin: data)
    if !result.succeeded {
      throw RemoteError.remoteCommandFailed(
        exitCode: result.exitCode,
        stderr: result.stderrString()
      )
    }
    // Invalidate any cached read of this path so a follow-up read sees the
    // freshly-written content.
    readCache.withValue { $0[path] = nil }
  }

  // MARK: connection state

  nonisolated func currentConnectionState() -> SSHClient.ConnectionState {
    connectionStateBox.value
  }

  nonisolated func invalidateReadCache() {
    readCache.withValue { $0.removeAll() }
  }

  // MARK: PTY command builder

  /// Build the `ssh ... -- sh -c '<remoteCommand>'` string Ghostty hands to
  /// `/bin/sh -c` as its `config.command`. Uses the same per-host config and
  /// ControlMaster socket the rest of `LiveRuntime` does, so the PTY-launched
  /// SSH session reuses the existing multiplexed channel rather than handshaking
  /// from scratch.
  nonisolated func buildPTYCommand(remoteCommand: String) -> String {
    // We can't easily ferry an array through Ghostty (it's a single string),
    // so we concatenate. All variable interpolation happens here, never on
    // the remote shell — `shellQuote` ensures the remote sh-c body is
    // POSIX-safe regardless of what `remoteCommand` contains.
    let sshArgs = baseSSHArgs() + ["-t", host.sshTarget, "--", "sh", "-c", shellQuote(remoteCommand)]
    let parts = (["/usr/bin/ssh"] + sshArgs).map(shellQuote)
    return parts.joined(separator: " ")
  }

  // MARK: - Subprocess plumbing

  nonisolated private func runSSH(
    arguments: [String],
    timeout: Duration,
    stdin: Data? = nil
  ) async throws -> SSHClient.ExecResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdinPipe: Pipe?
    if stdin != nil {
      let pipe = Pipe()
      process.standardInput = pipe
      stdinPipe = pipe
    } else {
      stdinPipe = nil
    }

    let stdoutBuf = LockIsolated(Data())
    let stderrBuf = LockIsolated(Data())
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      stdoutBuf.withValue { $0.append(chunk) }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      stderrBuf.withValue { $0.append(chunk) }
    }

    let exitStream = AsyncStream<Int32> { continuation in
      process.terminationHandler = { proc in
        continuation.yield(proc.terminationStatus)
        continuation.finish()
      }
    }

    do {
      try process.run()
    } catch {
      throw RemoteError.spawnFailed(underlying: "\(error)")
    }

    if let stdin, let stdinPipe {
      // Write on a detached task so we don't block waiting for the remote
      // process to start reading.
      Task.detached {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
        try? stdinPipe.fileHandleForWriting.close()
      }
    }

    let exitStatus = await withTaskGroup(of: Int32?.self) { group -> Int32? in
      group.addTask {
        for await status in exitStream { return status }
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }

    guard let exitStatus else {
      if process.isRunning { process.terminate() }
      // Drain after SIGTERM so we don't leak a zombie.
      _ = await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await _ in exitStream {}
        }
        group.addTask {
          try? await Task.sleep(for: .seconds(1))
        }
        defer { group.cancelAll() }
        await group.next()
      }
      connectionStateBox.setValue(.offline(reason: "Timed out after \(timeout)"))
      throw RemoteError.timeout(after: timeout)
    }

    let stdoutData = stdoutBuf.value
    let stderrData = stderrBuf.value

    // ssh exit codes ≥ 255 typically mean ssh itself failed (auth, dns,
    // network) rather than the remote command exiting that way.
    if exitStatus == 255 {
      let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
      connectionStateBox.setValue(.offline(reason: stderrText.firstLine()))
      throw RemoteError.connectionFailed(exitCode: exitStatus, stderr: stderrText)
    }

    // Any other terminal status — happy path or remote-command-failed — we
    // surface back to the caller as a successful exec. They decide what
    // exit-code semantics mean for their context.
    connectionStateBox.setValue(.connected)
    return SSHClient.ExecResult(stdout: stdoutData, stderr: stderrData, exitCode: exitStatus)
  }

  // MARK: - SSH config + paths

  /// Base ssh arguments shared by every invocation. Picks up our config file
  /// + control-master setup without depending on `~/.ssh/config`.
  nonisolated private func baseSSHArgs() -> [String] {
    var args: [String] = [
      "-F", sshConfigPath.path(percentEncoded: false),
      "-p", "\(host.port)",
      "-o", "BatchMode=yes",  // never prompt for passwords; agent-only
      "-o", "ConnectTimeout=8",
    ]
    if let identity = host.identityFile {
      args.append(contentsOf: ["-i", identity])
    }
    return args
  }

  nonisolated private func ensureControlDirectoryExists() throws {
    try FileManager.default.createDirectory(
      at: controlDirectory,
      withIntermediateDirectories: true,
      attributes: nil
    )
  }

  /// Write the per-host ssh config if absent. We avoid mutating an existing
  /// one so users who tweak it manually don't have their changes clobbered.
  nonisolated private func writeSSHConfigIfNeeded() throws {
    if FileManager.default.fileExists(atPath: sshConfigPath.path(percentEncoded: false)) {
      return
    }
    let config = """
      # Supacode-managed ssh config for host \(host.hostname).
      # Owned by Supacode. Manual edits will be preserved (we never overwrite),
      # but won't be merged into future regenerations either.

      Host \(host.hostname)
          User \(host.user)
          HostName \(host.hostname)
          Port \(host.port)
          ControlMaster auto
          ControlPath \(controlSocketTemplate)
          ControlPersist 10m
          ServerAliveInterval 30
          ServerAliveCountMax 3
          TCPKeepAlive yes
      """
    try config.data(using: .utf8)!.write(to: sshConfigPath, options: .atomic)
  }

  nonisolated private static func defaultControlDirectory() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appending(path: ".supacode/ssh", directoryHint: .isDirectory)
  }

  // MARK: - Cache

  nonisolated private struct CacheEntry: Sendable {
    var data: Data
    var fetchedAt: ContinuousClock.Instant

    nonisolated var isStale: Bool {
      ContinuousClock.now - fetchedAt > SSHClient.readFileCacheTTL
    }
  }
}

// MARK: - Helpers

/// POSIX single-quote escaping. Same shape as ZmxAttach.shellQuote — we
/// could hoist this to a shared `ShellQuoting` namespace later if more callers
/// need it.
nonisolated private func shellQuote(_ value: String) -> String {
  let escaped = value.replacing("'", with: "'\\''")
  return "'\(escaped)'"
}

extension String {
  nonisolated fileprivate func sanitizedForFilename() -> String {
    self.replacing("/", with: "_").replacing("..", with: "_")
  }

  nonisolated fileprivate func firstLine() -> String {
    self.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
  }
}
