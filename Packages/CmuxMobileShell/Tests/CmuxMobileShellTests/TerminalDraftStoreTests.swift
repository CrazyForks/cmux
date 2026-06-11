import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for ``TerminalDraftStore``: per-terminal keying, empty-draft
/// removal, clear semantics, and durability across store instances (the
/// app-relaunch case). Each test uses a unique temp file so they never touch the
/// user's container and can run in parallel.
@Suite struct TerminalDraftStoreTests {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-draft-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    private func makeStore(at url: URL) throws -> TerminalDraftStore {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return TerminalDraftStore(fileURL: url)
    }

    @Test func savesAndLoadsPerTerminal() async throws {
        let store = try makeStore(at: tempFileURL())
        await store.saveDraft("git status", forTerminalID: "term-a")
        await store.saveDraft("npm test", forTerminalID: "term-b")

        let a = await store.draft(forTerminalID: "term-a")
        let b = await store.draft(forTerminalID: "term-b")
        #expect(a == "git status")
        #expect(b == "npm test")
        // A terminal with no draft reads nil, not another terminal's text.
        let missing = await store.draft(forTerminalID: "term-c")
        #expect(missing == nil)
    }

    @Test func emptyOrWhitespaceDraftRemovesEntry() async throws {
        let store = try makeStore(at: tempFileURL())
        await store.saveDraft("hello", forTerminalID: "term-a")
        await store.saveDraft("   \n ", forTerminalID: "term-a")
        let restored = await store.draft(forTerminalID: "term-a")
        #expect(restored == nil)
    }

    @Test func clearDraftRemovesOnlyThatTerminal() async throws {
        let store = try makeStore(at: tempFileURL())
        await store.saveDraft("keep", forTerminalID: "term-a")
        await store.saveDraft("drop", forTerminalID: "term-b")
        await store.clearDraft(forTerminalID: "term-b")
        let a = await store.draft(forTerminalID: "term-a")
        let b = await store.draft(forTerminalID: "term-b")
        #expect(a == "keep")
        #expect(b == nil)
    }

    @Test func clearAllDraftsEmptiesEveryTerminal() async throws {
        let store = try makeStore(at: tempFileURL())
        await store.saveDraft("a", forTerminalID: "term-a")
        await store.saveDraft("b", forTerminalID: "term-b")
        await store.clearAllDrafts()
        let a = await store.draft(forTerminalID: "term-a")
        let b = await store.draft(forTerminalID: "term-b")
        #expect(a == nil)
        #expect(b == nil)
    }

    @Test func draftsSurviveANewStoreInstance() async throws {
        // The app-relaunch case: a fresh store over the same file reads back what a
        // prior instance wrote.
        let url = tempFileURL()
        let first = try makeStore(at: url)
        await first.saveDraft("survives kill", forTerminalID: "term-a")

        let second = try makeStore(at: url)
        let restored = await second.draft(forTerminalID: "term-a")
        #expect(restored == "survives kill")
    }

    @Test func corruptFileLoadsAsEmptyInsteadOfCrashing() async throws {
        let url = tempFileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json{".utf8).write(to: url)
        let store = TerminalDraftStore(fileURL: url)
        let missing = await store.draft(forTerminalID: "term-a")
        #expect(missing == nil)
        // And it can still save over the corrupt file.
        await store.saveDraft("recovered", forTerminalID: "term-a")
        #expect(await store.draft(forTerminalID: "term-a") == "recovered")
    }
}
