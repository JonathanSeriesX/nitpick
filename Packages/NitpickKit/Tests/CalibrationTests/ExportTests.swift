import Foundation
import Testing
import ColorScience
import PatternLink
@testable import Calibration

@Suite struct ExportTests {
    @Test func csvHasOneRowPerPatch() async throws {
        let rig = Rig(seed: 23)
        try await rig.connect()
        let set = try await rig.measurer().measureSet(.full, target: .sdrMovie)
        let lines = SessionExporter.csv(set).split(separator: "\n")
        let header = lines[0].split(separator: ",")
        #expect(header.first == "section" && header.count == 18)
        let patches = set.grayscale.count + set.nearBlack.count + set.primariesSecondaries.count + set.saturationSweeps.count + set.verificationPatches.count
        #expect(patches == 21 + 4 + 12 + 24 + 36)
        #expect(lines.count == 1 + patches)
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            #expect(fields.count == header.count, "\(line)")
            #expect(fields[2...16].allSatisfy { Double($0) != nil }, "\(line)")
        }
    }

    @Test func cubeAndLUT1DText() {
        var lut = LUT3D.identity(size: 17)
        lut[1, 0, 0] = RGB(r: 0.07, g: 0.001, b: 0)
        let text = SessionExporter.cube(lut, title: "Nitpick \"expert1\"")
        let lines = text.split(separator: "\n")
        #expect(lines[0] == "TITLE \"Nitpick 'expert1'\"" && lines.contains("LUT_3D_SIZE 17"))
        let data = lines.filter { $0.first.map { $0.isNumber || $0 == "-" } ?? false }
        #expect(data.count == 17 * 17 * 17)
        let rows = data.map { $0.split(separator: " ").map { Double($0)! } }
        #expect(rows.allSatisfy { $0.count == 3 })
        #expect(rows[1] == [0.07, 0.001, 0])          // red changes fastest
        #expect(rows[17] == [0, 0.0625, 0])
        let oneD = SessionExporter.lut1DText(.identity(size: 1024)).split(separator: "\n")
        #expect(oneD[0] == "LUT_1D_SIZE 1024" && oneD.count == 3 + 1024)
        #expect(oneD.last == "1.000000 1.000000 1.000000")
    }

    @Test func sessionJSONRoundTrips() throws {
        var session = CalibrationSession(profile: .dolbyVision(source: UUID()), notes: "test")
        session.restorePoint = RestorePoint(inputID: "HDMI_1", settings: PictureSettings(pictureMode: "dolby_cinema_dark", values: ["contrast": .number(85)]))
        let data = try SessionExporter.json(session)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CalibrationSession.self, from: data)
        #expect(decoded.id == session.id && decoded.profile == session.profile && decoded.restorePoint?.settings.values == ["contrast": .number(85)])
        #expect(RestorePoint.label == "Settings snapshot (LUT state not readable)")
    }
}
