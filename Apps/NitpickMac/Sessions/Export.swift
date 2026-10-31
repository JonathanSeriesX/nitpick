import Calibration
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ExportKind: String, CaseIterable, Identifiable {
    case csv, json, cube, lut1D
    var id: String { rawValue }

    var title: String {
        switch self {
        case .csv: "Measurements (CSV)…"
        case .json: "Session (JSON)…"
        case .cube: "3D LUT (.cube)…"
        case .lut1D: "1D LUT (.cube)…"
        }
    }

    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        case .cube, .lut1D: UTType(filenameExtension: "cube", conformingTo: .plainText) ?? .plainText
        }
    }

    func isAvailable(for session: CalibrationSession) -> Bool {
        switch self {
        case .csv: session.result != nil
        case .json: true
        case .cube: session.generatedLUT3D != nil
        case .lut1D: session.generatedLUT1D != nil
        }
    }
}

/// A file for `fileExporter`.
nonisolated struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ExportRequest {
    var file: ExportFile
    var contentType: UTType
    var filename: String

    init(session: CalibrationSession, kind: ExportKind) throws {
        let stamp = session.createdAt.formatted(.iso8601.year().month().day())
        let base = "Nitpick \(session.profile.name) \(stamp)"
        contentType = kind.contentType
        switch kind {
        case .csv:
            guard let result = session.result else { throw CalibrationError.precondition("The session has no measurements yet.") }
            file = ExportFile(data: Data(Self.csv(result).utf8))
            filename = "\(base) measurements"
        case .json:
            file = ExportFile(data: try SessionExporter.json(session))
            filename = base
        case .cube:
            guard let lut = session.generatedLUT3D else { throw CalibrationError.precondition("This session generated no 3D LUT.") }
            file = ExportFile(data: Data(SessionExporter.cube(lut, title: base).utf8))
            filename = "\(base) 3D LUT"
        case .lut1D:
            guard let lut = session.generatedLUT1D else { throw CalibrationError.precondition("This session generated no 1D LUT.") }
            file = ExportFile(data: Data(SessionExporter.lut1DText(lut).utf8))
            filename = "\(base) 1D LUT"
        }
    }

    /// Before, after and verification sets in one table, with a leading `set` column.
    static func csv(_ result: SessionResult) -> String {
        var lines: [String] = []
        for (name, set) in [("before", result.before), ("after", result.after), ("verification", result.verification)] {
            let rows = SessionExporter.csv(set).split(separator: "\n", omittingEmptySubsequences: true)
            if lines.isEmpty, let header = rows.first { lines.append("set," + header) }
            lines += rows.dropFirst().map { "\(name),\($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
