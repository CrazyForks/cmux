public import Foundation
import os

private let terminalDraftStoreLog = Logger(subsystem: "com.cmuxterm.app", category: "TerminalDraftStore")

/// JSON-file-backed ``TerminalDraftStoring`` that persists per-terminal composer
/// drafts to the app container.
///
/// Drafts are tiny (a few unsent keystrokes per terminal), so the whole map is
/// kept in memory and written through on every change as one small JSON file.
/// An `actor` serializes the in-memory map and the file writes, so the type is
/// genuinely `Sendable` and never blocks the main thread.
///
/// The file lives under **Application Support** (not Caches, which the OS may
/// evict) so drafts survive an app kill/relaunch, which is the whole point.
///
/// ```swift
/// let store = try TerminalDraftStore()
/// await store.saveDraft("git status", forTerminalID: "ws-1-term-2")
/// // ... app relaunch ...
/// let restored = await store.draft(forTerminalID: "ws-1-term-2") // "git status"
/// ```
///
/// Construct it once at the app composition root and inject it as
/// `any TerminalDraftStoring`. Tests pass a temp-directory URL so they never
/// touch the user's container.
public actor TerminalDraftStore: TerminalDraftStoring {
    private let fileURL: URL
    private let fileManager: FileManager

    /// The in-memory draft map (terminal id raw string → draft text), lazily
    /// loaded from disk on first access so the synchronous initializer does no
    /// I/O. `nil` until the first ``ensureLoaded()``.
    private var drafts: [String: String]?

    /// The default on-disk location for the drafts file.
    /// - Parameter fileManager: File manager used to resolve and create the directory.
    /// - Returns: The `terminal-drafts.json` URL under Application Support/cmux.
    /// - Throws: Any error thrown while resolving or creating the directory.
    public static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("cmux", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("terminal-drafts.json")
    }

    /// Create a store backed by `fileURL`.
    /// - Parameters:
    ///   - fileURL: On-disk JSON file location for the draft map.
    ///   - fileManager: File manager used for reads/writes. Defaults to `.default`.
    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// Create a store at ``defaultFileURL(fileManager:)``.
    /// - Throws: Any error thrown while resolving or creating the directory.
    public init() throws {
        self.init(fileURL: try Self.defaultFileURL())
    }

    public func draft(forTerminalID terminalID: String) -> String? {
        ensureLoaded()[terminalID]
    }

    public func saveDraft(_ draft: String, forTerminalID terminalID: String) {
        var map = ensureLoaded()
        // An empty/whitespace draft is "no draft": drop the entry so a cleared
        // field never resurrects on relaunch and the file does not grow stale
        // empty keys. A no-op write (key already absent) is skipped.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard map[terminalID] != nil else { return }
            map[terminalID] = nil
        } else {
            guard map[terminalID] != draft else { return }
            map[terminalID] = draft
        }
        drafts = map
        persist(map)
    }

    public func clearDraft(forTerminalID terminalID: String) {
        var map = ensureLoaded()
        guard map[terminalID] != nil else { return }
        map[terminalID] = nil
        drafts = map
        persist(map)
    }

    public func clearAllDrafts() {
        if ensureLoaded().isEmpty { return }
        drafts = [:]
        persist([:])
    }

    /// Load the draft map from disk once, caching it for subsequent calls. A
    /// missing or unreadable file yields an empty map (a corrupt drafts file
    /// should not crash or wedge the composer).
    private func ensureLoaded() -> [String: String] {
        if let drafts { return drafts }
        let loaded: [String: String]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            loaded = decoded
        } else {
            loaded = [:]
        }
        drafts = loaded
        return loaded
    }

    /// Write the map to disk atomically. A write failure is logged and swallowed:
    /// the in-memory value still reflects the live draft, and losing durability
    /// for one keystroke is preferable to surfacing an I/O error into the
    /// composer.
    private func persist(_ map: [String: String]) {
        do {
            let data = try JSONEncoder().encode(map)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            terminalDraftStoreLog.error(
                "failed to persist terminal drafts: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
