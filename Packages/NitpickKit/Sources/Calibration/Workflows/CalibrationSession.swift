import ColorScience
import Foundation

/// A settings snapshot, LUT state not readable: the picture settings of the calibrated mode as read before any
/// change. LUT/3D LUT/tonemap/DV data cannot be read back from the TV, so this is never a factory backup.
public struct RestorePoint: Codable, Hashable, Sendable {
    /// The label the UI shows for this object.
    public static let label = "Settings snapshot (LUT state not readable)"
    public var inputID: String
    public var settings: PictureSettings

    public init(inputID: String, settings: PictureSettings) {
        self.inputID = inputID
        self.settings = settings
    }
}

public struct SessionResult: Codable, Sendable {
    public var before: MeasurementSet
    public var after: MeasurementSet
    /// Independent verification patches (ColorChecker + seeded random), never used by an optimizer.
    public var verification: MeasurementSet
    public var adjustments: [AdjustmentStep]
    /// Human-readable list of externalpq uploads ("1D LUT expert1", …).
    public var lutsUploaded: [String]
    public var restorePoint: RestorePoint?
    public var toneAnalysis: HDRToneReport?
    /// Seconds per stage on the session's clock.
    public var durations: [String: Double]
    public var warnings: [String]
    /// Every threshold in `failures` passed for `after` and `verification`.
    public var passed: Bool
    public var failures: [String]
}

public struct CalibrationSession: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case draft, running, completed, cancelled, failed, interrupted }

    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var profile: SessionProfile
    public var tvModel: String?
    public var meterModel: String?
    public var status: Status
    public var restorePoint: RestorePoint?
    public var result: SessionResult?
    public var generatedLUT1D: LUT1D?
    public var generatedLUT3D: LUT3D?
    public var dolbyConfig: DolbyVisionConfig?
    public var notes: String

    public init(id: UUID = UUID(), profile: SessionProfile, createdAt: Date = Date(), notes: String = "") {
        self.id = id
        self.createdAt = createdAt
        updatedAt = createdAt
        self.profile = profile
        status = .draft
        self.notes = notes
    }
}

/// Sessions as one JSON file each (`<id>.json`) in a directory.
public final class SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public func save(_ session: CalibrationSession) throws {
        try JSONEncoder().encode(session).write(to: url(session.id), options: .atomic)
    }

    public func load(id: UUID) throws -> CalibrationSession {
        try JSONDecoder().decode(CalibrationSession.self, from: Data(contentsOf: url(id)))
    }

    /// All sessions, oldest first. Unreadable files are skipped.
    public func list() throws -> [CalibrationSession] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(CalibrationSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func delete(id: UUID) throws { try FileManager.default.removeItem(at: url(id)) }

    /// Marks sessions left `.running` (app quit or crashed mid-run) as `.interrupted` and returns their ids.
    /// Call once at launch, before any workflow starts.
    @discardableResult
    public func markInterrupted() throws -> [UUID] {
        var changed: [UUID] = []
        for var session in try list() where session.status == .running {
            session.status = .interrupted
            try save(session)
            changed.append(session.id)
        }
        return changed
    }
}

/// Append-only JSONL log of every reading, one file per session (`<id>.jsonl`).
public final class MeasurementHistory: Sendable {
    public struct Record: Codable, Hashable, Sendable {
        public var sessionID: UUID
        public var stage: String
        public var stimulus: SignalRGB
        public var reading: MeterReading
        public var reference: XYZ?
    }

    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).jsonl") }

    public func append(_ record: Record) throws {
        var line = try JSONEncoder().encode(record)
        line.append(0x0A)
        let file = url(record.sessionID)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    public func records(for sessionID: UUID) throws -> [Record] {
        guard let data = try? Data(contentsOf: url(sessionID)) else { return [] }
        return try data.split(separator: 0x0A).map { try JSONDecoder().decode(Record.self, from: Data($0)) }
    }
}
