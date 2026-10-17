// ExtensionsDirectoryWatcher.swift
// OpenClip
//
// Hot-reloads extension actions when ~/.openclip/extensions changes. Polls and diffs a recursive
// snapshot instead of using FSEvents, and reloads only after two consecutive ticks agree, so a
// package still being copied in is not picked up half-written.
import Foundation
import Core

/// Immutable fingerprint of a directory tree. Two equal snapshots mean no file changed.
struct ExtensionsSnapshot: Equatable {
    /// Relative file path (from the watched root) -> content modification date.
    let files: [String: Date]

    /// Recursively fingerprints non-hidden files under `root`; nil if missing or unreadable.
    /// Hidden items (`.install_staging_*`, .DS_Store) are skipped.
    static func build(from root: URL) -> ExtensionsSnapshot? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return nil }

        let rootPath = root.standardizedFileURL.path
        var files: [String: Date] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory != true,
                  let date = values.contentModificationDate else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(path.dropFirst(rootPath.count + 1))
            files[relativePath] = date
        }
        return ExtensionsSnapshot(files: files)
    }
}

/// Polls a directory and fires a reload after a change settles.
final class ExtensionsDirectoryWatcher: @unchecked Sendable {
    /// A change settles within ~2× this interval (two agreeing ticks).
    static let defaultPollInterval: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "com.talkra.extensions.watch")
    private var timer: DispatchSourceTimer?

    private let reload: @MainActor () async -> Void

    // State below is confined to `queue`.
    private var root: URL?
    private var lastSeen: ExtensionsSnapshot?
    private var pending: ExtensionsSnapshot?
    private var reloadInFlight = false
    private var needsReload = false

    init(reload: @escaping @MainActor () async -> Void) {
        self.reload = reload
    }

    func start(watching root: URL, interval: TimeInterval = ExtensionsDirectoryWatcher.defaultPollInterval) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.root = root
            self.lastSeen = ExtensionsSnapshot.build(from: root)
            self.pending = nil
            let newTimer = DispatchSource.makeTimerSource(queue: self.queue)
            newTimer.schedule(deadline: .now() + interval, repeating: interval)
            newTimer.setEventHandler { [weak self] in
                self?.poll()
            }
            newTimer.resume()
            self.timer = newTimer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.root = nil
            self?.lastSeen = nil
            self?.pending = nil
        }
    }

    /// One synchronous poll tick, so tests can drive the settle logic without the timer.
    func pollOnce() {
        queue.sync { [weak self] in
            self?.poll()
        }
    }

    /// Runs on `queue` only.
    private func poll() {
        guard let root else { return }
        guard let current = ExtensionsSnapshot.build(from: root) else {
            // Missing or unreadable (e.g. a package mid-replacement): skip, so the registry is kept.
            return
        }
        if current == lastSeen {
            pending = nil
            return
        }
        guard let pending else {
            // First differing tick: remember it and wait for a second agreeing tick.
            self.pending = current
            return
        }
        guard pending == current else {
            // Still settling (kept changing since the last tick); slide the reference forward.
            self.pending = current
            return
        }
        lastSeen = current
        self.pending = nil
        guard !reloadInFlight else {
            // Defer until the in-flight reload completes, so loadExtensions never races the registry.
            needsReload = true
            return
        }
        Log.extensions.notice("Extensions directory changed; reloading extensions")
        dispatchReload()
    }

    /// Starts a reload task on the MainActor. Called from `queue` so the in-flight flags stay confined.
    private func dispatchReload() {
        reloadInFlight = true
        Task { @MainActor [weak self] in
            await self?.reload()
            self?.reloadCompleted()
        }
    }

    /// Runs on the MainActor after `reload`; hops back to `queue` to clear the in-flight flag.
    private func reloadCompleted() {
        queue.async { [weak self] in
            guard let self else { return }
            self.reloadInFlight = false
            guard self.needsReload else { return }
            self.needsReload = false
            Log.extensions.notice("Extensions directory changed while reloading; reloading again")
            self.dispatchReload()
        }
    }
}
