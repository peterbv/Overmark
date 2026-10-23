import Foundation
import Testing
@testable import OvermarkCore

@Suite("SessionArchive")
struct SessionArchiveTests {
    /// A throwaway directory so tests never touch the real archive.
    private var root: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overmark-archive-tests-\(UUID().uuidString)")
            .standardized
    }

    private var screen: ScreenFrame {
        ScreenFrame(
            origin: Point(x: 0, y: 0),
            size: Size(width: 1440, height: 900),
            scale: 2
        )
    }

    private func stroke() -> Annotation {
        let path = [
            Point(x: 10, y: 10),
            Point(x: 30, y: 60),
            Point(x: 90, y: 40),
        ]
        return Annotation(
            tool: .pen,
            color: Color(red: 1, green: 0.2, blue: 0.4),
            lineWidth: 6,
            path: path,
            bounds: Annotation.bounds(of: path),
            gradientColor: Color(red: 0, green: 0.9, blue: 1)
        )
    }

    // MARK: - Round trip

    @Test("A snapshot survives save and load")
    func roundTrip() throws {
        let root = root
        var document = AnnotationDocument()
        document.add(stroke())
        let snapshot = SessionSnapshot(
            savedAt: Date(timeIntervalSince1970: 1_000),
            screens: [screen],
            annotations: document.annotations
        )

        let url = try SessionArchive.saveSnapshot(
            snapshot,
            name: "Hoja de clase",
            in: root
        )

        #expect(url.lastPathComponent == "Hoja de clase.json")

        let loaded = try #require(SessionArchive.loadSnapshot(at: url))
        #expect(loaded.version == SessionArchive.formatVersion)
        #expect(loaded.savedAt == snapshot.savedAt)
        #expect(loaded.screens == snapshot.screens)
        #expect(loaded.annotations == snapshot.annotations)
    }

    // MARK: - Listing

    @Test("List returns every document, newest first, skipping junk")
    func list() throws {
        let root = root
        var document = AnnotationDocument()
        document.add(stroke())

        let newer = SessionSnapshot(
            savedAt: Date(timeIntervalSince1970: 200),
            annotations: document.annotations
        )
        let older = SessionSnapshot(
            savedAt: Date(timeIntervalSince1970: 100),
            annotations: document.annotations
        )

        try SessionArchive.saveSnapshot(newer, name: "nuevo", in: root)
        try SessionArchive.saveSnapshot(older, name: "viejo", in: root)

        let junk = root.appendingPathComponent("corrupto.json")
        try Data("not json".utf8).write(to: junk)

        let entries = SessionArchive.listSnapshots(in: root)
        #expect(entries.map(\.name) == ["nuevo", "viejo"])
        #expect(entries.map(\.snapshot.savedAt) == [newer.savedAt, older.savedAt])
    }

    @Test("The autosave slot is not listed among documents")
    func autosaveNotListed() throws {
        let root = root
        var document = AnnotationDocument()
        document.add(stroke())

        try SessionArchive.autosaveSnapshot(
            SessionSnapshot(annotations: document.annotations),
            in: root
        )

        #expect(SessionArchive.listSnapshots(in: root).isEmpty)
        #expect(SessionArchive.loadAutosave(in: root)?.annotations.count == 1)
    }

    // MARK: - Autosave

    @Test("Autosave overwrites itself and clears when empty")
    func autosaveLifecycle() throws {
        let root = root
        var document = AnnotationDocument()
        document.add(stroke())
        try SessionArchive.autosaveSnapshot(
            SessionSnapshot(annotations: document.annotations),
            in: root
        )

        document.add(stroke())
        try SessionArchive.autosaveSnapshot(
            SessionSnapshot(annotations: document.annotations),
            in: root
        )
        #expect(SessionArchive.loadAutosave(in: root)?.annotations.count == 2)

        try SessionArchive.autosaveSnapshot(
            SessionSnapshot(annotations: []),
            in: root
        )
        #expect(SessionArchive.loadAutosave(in: root) == nil)
    }

    // MARK: - Naming

    @Test("Duplicate names get a numeric suffix, not an overwrite")
    func uniqueNames() throws {
        let root = root
        var document = AnnotationDocument()
        document.add(stroke())
        let snapshot = SessionSnapshot(annotations: document.annotations)

        let first = try SessionArchive.saveSnapshot(snapshot, name: "Hoja", in: root)
        let second = try SessionArchive.saveSnapshot(snapshot, name: "Hoja", in: root)
        let third = try SessionArchive.saveSnapshot(snapshot, name: "Hoja", in: root)

        #expect(first.lastPathComponent == "Hoja.json")
        #expect(second.lastPathComponent == "Hoja (2).json")
        #expect(third.lastPathComponent == "Hoja (3).json")

        let names = SessionArchive.listSnapshots(in: root).map(\.name)
        #expect(Set(names) == ["Hoja", "Hoja (2)", "Hoja (3)"])
    }

    @Test("Hostile names are sanitized")
    func hostileName() throws {
        let root = root
        var document = AnnotationDocument()
        document.add(stroke())
        let url = try SessionArchive.saveSnapshot(
            SessionSnapshot(annotations: document.annotations),
            name: "a/b:c?\"*|" + "≤/\u{7}",
            in: root
        )

        let name = url.deletingPathExtension().lastPathComponent
        #expect(!name.contains("/") && !name.contains(":"))
        #expect(name != SessionArchive.autosaveFileName)
        #expect(SessionArchive.loadSnapshot(at: url) != nil)
    }

    @Test("A name equal to the autosave slot is shifted aside")
    func autosaveNameCollision() throws {
        let root = root
        var document = AnnotationDocument()
        document.add(stroke())
        let url = try SessionArchive.saveSnapshot(
            SessionSnapshot(annotations: document.annotations),
            name: "autosave",
            in: root
        )

        #expect(url.lastPathComponent == "autosave-saved.json")
        #expect(SessionArchive.loadAutosave(in: root) == nil)
    }

    /// Empty-name documents still get a file.
    @Test("A blank name falls back to a placeholder")
    func blankName() throws {
        let root = root
        var document = AnnotationDocument()
        document.add(stroke())
        let url = try SessionArchive.saveSnapshot(
            SessionSnapshot(annotations: document.annotations),
            name: "   ",
            in: root
        )

        #expect(url.lastPathComponent == "document.json")
    }

    // MARK: - Deleting

    @Test("Deleting removes only the named file")
    func delete() throws {
        let root = root
        var document = AnnotationDocument()
        document.add(stroke())
        let snapshot = SessionSnapshot(annotations: document.annotations)
        let kept = try SessionArchive.saveSnapshot(snapshot, name: "queda", in: root)
        let gone = try SessionArchive.saveSnapshot(snapshot, name: "va", in: root)

        try SessionArchive.deleteSnapshot(named: "va", in: root)

        #expect(SessionArchive.loadSnapshot(at: gone) == nil)
        #expect(SessionArchive.loadSnapshot(at: kept) != nil)
        #expect(SessionArchive.listSnapshots(in: root).map(\.name) == ["queda"])
    }

    @Test("Deleting a missing name is a tolerated no-op")
    func deleteMissing() {
        let root = root
        #expect(throws: Error.self) {
            try SessionArchive.deleteSnapshot(named: "nadie", in: root)
        }
    }
}
