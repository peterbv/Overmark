import Foundation

/// A set of annotations plus the screen layout they were drawn on, at a moment
/// in time.
///
/// This is the unit of document persistence. `AnnotationDocument` already
/// persists its own annotations when encoded, but undo history is
/// session-scoped and the screens that the annotations were drawn against are
/// worth knowing too — older formats or a changed display layout can degrade a
/// restored session gracefully instead of lying to the user.
public struct SessionSnapshot: Hashable, Sendable, Codable {
    /// Format version, so future layout changes can migrate old files.
    public var version: Int
    /// When the snapshot was written.
    public var savedAt: Date
    /// Screen layout — global AppKit frames — captured when saving.
    public var screens: [ScreenFrame]
    /// The annotations themselves, in screen space.
    public var annotations: [Annotation]

    public init(
        version: Int = SessionArchive.formatVersion,
        savedAt: Date = Date(),
        screens: [ScreenFrame] = [],
        annotations: [Annotation] = []
    ) {
        self.version = version
        self.savedAt = savedAt
        self.screens = screens
        self.annotations = annotations
    }
}

/// Reads and writes annotation snapshots on disk as JSON files.
///
/// Files live in a per-user folder; every function takes an optional root so
/// tests can point at a temporary directory instead of touching the real one.
/// Corrupted files are treated as absent: persistence is a convenience for
/// annotating, not a database, and a bad file should degrade to "not there".
public enum SessionArchive {
    /// Current snapshot format version.
    public static let formatVersion = 1

    /// Fixed file name used for the autosave slot.
    public static let autosaveFileName = "autosave"

    /// One file on the archive list: where it is and what it holds.
    public struct Entry: Identifiable, Hashable {
        public let url: URL
        public let snapshot: SessionSnapshot

        public var id: URL { url }

        /// File name without the `.json` extension — the document name.
        public var name: String {
            url.deletingPathExtension().lastPathComponent
        }
    }

    // MARK: - Directory

    /// The archive directory: `<Application Support>/Overmark/Documents`.
    ///
    /// The directory is created if missing so a theoretical first call has a
    /// place to write; files are never assumed to exist.
    public static func directory(root: URL? = nil) -> URL {
        let root = root ?? defaultRoot
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        }
        return root
    }

    /// Root behind `directory(root: nil)`.
    private static var defaultRoot: URL {
        guard
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Overmark/Documents")
        }
        return support
            .appendingPathComponent("Overmark", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }

    // MARK: - Saving

    /// Writes a snapshot under a user-visible name, sanitizing collisions.
    ///
    /// Returns the URL of the file that was written (the name may be suffixed,
    /// e.g. `Hoja (2).json`, if it was already taken).
    @discardableResult
    public static func saveSnapshot(
        _ snapshot: SessionSnapshot,
        name: String,
        in root: URL? = nil
    ) throws -> URL {
        let directory = directory(root: root)
        let name = sanitizedFileName(name)
        let url = availableURL(
            for: name,
            in: directory,
            taken: directoryUrls(in: directory)
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Writes the autosave slot, or clears it when the document is empty.
    public static func autosaveSnapshot(
        _ snapshot: SessionSnapshot,
        in root: URL? = nil
    ) throws {
        let directory = directory(root: root)
        let url = directory.appendingPathComponent("\(autosaveFileName).json")
        if snapshot.annotations.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Reading

    /// Loads the autosave snapshot, or `nil` when absent or unreadable.
    public static func loadAutosave(in root: URL? = nil) -> SessionSnapshot? {
        let directory = directory(root: root)
        let url = directory.appendingPathComponent("\(autosaveFileName).json")
        return loadSnapshot(at: url)
    }

    /// Loads a snapshot from a specific file, tolerating corruption.
    public static func loadSnapshot(at url: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Every saved document, newest first. Autosave and corrupted files skip.
    public static func listSnapshots(in root: URL? = nil) -> [Entry] {
        let directory = directory(root: root)
        return directoryUrls(in: directory)
            .compactMap { url -> Entry? in
                guard
                    url.isFileURL,
                    url.pathExtension.lowercased() == "json",
                    url.deletingPathExtension().lastPathComponent
                        != autosaveFileName
                else { return nil }
                guard let snapshot = loadSnapshot(at: url) else { return nil }
                return Entry(url: url, snapshot: snapshot)
            }
            .sorted { $0.snapshot.savedAt > $1.snapshot.savedAt }
    }

    // MARK: - Deleting

    /// Deletes the document file with the given name, if it exists.
    public static func deleteSnapshot(named name: String, in root: URL? = nil) throws {
        let directory = directory(root: root)
        let url = directory.appendingPathComponent("\(name).json")
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - File naming

    /// Builds a URL that does not collide with existing files.
    ///
    /// `Hoja.json` → `Hoja (2).json` → `Hoja (3).json`, and so on.
    private static func availableURL(
        for name: String,
        in directory: URL,
        taken: [URL]
    ) -> URL {
        let base = name.lowercased()
        let takenNames = Set(taken.map { $0.deletingPathExtension().lastPathComponent.lowercased() })

        if !takenNames.contains(base) {
            return directory.appendingPathComponent("\(name).json")
        }
        for n in 2... {
            let candidate = "\(name) (\(n))"
            if !takenNames.contains(
                candidate.lowercased()
            ) {
                return directory.appendingPathComponent("\(candidate).json")
            }
        }
        // Unreachable in practice, but the compiler demands a return.
        return directory.appendingPathComponent("\(name).json")
    }

    /// JSON files in a directory, tolerating a missing directory.
    private static func directoryUrls(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    /// Strips characters that are invalid in (or hostile to) file names.
    ///
    /// Slashes, colons and control characters become spaces; surrounding
    /// whitespace and empty names fall back to a neutral placeholder. A name
    /// equal to the autosave file name is shifted aside so it cannot shadow
    /// the autosave slot.
    static func sanitizedFileName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(
            of: "[/:\\\\\\?%*|\"<>]",
            with: " ",
            options: .regularExpression
        )
        // Control characters, non-printable once the regex above is applied.
        cleaned = cleaned.unicodeScalars
            .filter {
                let value = $0.value
                return value >= 0x20 && value != 0x7F
                    && !(value >= 0x80 && value <= 0x9F)
            }
            .map(String.init)
            .joined()
        cleaned = cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            cleaned = "document"
        }
        if cleaned.compare(SessionArchive.autosaveFileName, options: .caseInsensitive) == .orderedSame {
            cleaned = "\(cleaned)-saved"
        }
        return cleaned
    }
}
