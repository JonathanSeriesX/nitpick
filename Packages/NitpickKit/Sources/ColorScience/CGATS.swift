import Foundation

/// One table of a CGATS.17 / Argyll text file (.ccss, .ccmx, .ti3 …). Values are kept as strings, quotes removed.
public struct CGATSFile: Hashable, Sendable {
    /// File identifier from the first line, e.g. "CCSS", "CCMX", "CTI3".
    public var fileType: String
    /// Header keywords (`DESCRIPTOR "…"`, `NUMBER_OF_SETS 3` …). `KEYWORD "X"` declarations are not stored.
    public var keywords: [String: String]
    /// Column names from `BEGIN_DATA_FORMAT … END_DATA_FORMAT`.
    public var fields: [String]
    /// Data sets from `BEGIN_DATA … END_DATA`, each with `fields.count` values.
    public var rows: [[String]]

    public init(fileType: String, keywords: [String: String], fields: [String], rows: [[String]]) {
        self.fileType = fileType
        self.keywords = keywords
        self.fields = fields
        self.rows = rows
    }

    /// The named column as numbers; nil if the field is missing or any value is not a number.
    public func column(_ name: String) -> [Double]? {
        guard let i = fields.firstIndex(of: name) else { return nil }
        let values = rows.compactMap { Double($0[i]) }
        return values.count == rows.count ? values : nil
    }
}

public enum CGATSError: Error, Hashable, Sendable {
    case empty
    case missingDataFormat
    case missingData
    case malformed(String)
}

public enum CGATS {
    /// Parses the first table of an Argyll-style CGATS text: identifier line, `KEYWORD "value"` header lines,
    /// `BEGIN_DATA_FORMAT … END_DATA_FORMAT`, `BEGIN_DATA … END_DATA`; `#` starts a comment outside quotes.
    /// `NUMBER_OF_FIELDS` / `NUMBER_OF_SETS`, when present, must match the data.
    // ponytail: later tables in multi-table files (e.g. .ti3 with a CAL section) are ignored; add if ever needed.
    public static func parse(_ text: String) throws -> CGATSFile {
        enum Section { case header, format, data, done }
        var fileType: String?
        var keywords: [String: String] = [:]
        var fields: [String] = []
        var values: [String] = []
        var section = Section.header
        for line in text.split(whereSeparator: \.isNewline) where section != .done {
            let tokens = tokenize(line)
            guard let first = tokens.first else { continue }
            if fileType == nil {
                fileType = first
                continue
            }
            switch section {
            case .format: if first == "END_DATA_FORMAT" { section = .header } else { fields += tokens }
            case .data: if first == "END_DATA" { section = .done } else { values += tokens }
            case .header:
                switch first {
                case "BEGIN_DATA_FORMAT": section = .format
                case "BEGIN_DATA": section = .data
                case "KEYWORD": break
                default: keywords[first] = tokens.dropFirst().joined(separator: " ")
                }
            case .done: break
            }
        }
        guard let fileType else { throw CGATSError.empty }
        guard !fields.isEmpty else { throw CGATSError.missingDataFormat }
        guard section == .done else { throw section == .data ? CGATSError.malformed("missing END_DATA") : CGATSError.missingData }
        guard values.count % fields.count == 0 else {
            throw CGATSError.malformed("\(values.count) data values do not fill rows of \(fields.count) fields")
        }
        let rows = stride(from: 0, to: values.count, by: fields.count).map { Array(values[$0..<($0 + fields.count)]) }
        if let n = keywords["NUMBER_OF_FIELDS"].flatMap(Int.init), n != fields.count {
            throw CGATSError.malformed("NUMBER_OF_FIELDS \(n) but \(fields.count) fields")
        }
        if let n = keywords["NUMBER_OF_SETS"].flatMap(Int.init), n != rows.count {
            throw CGATSError.malformed("NUMBER_OF_SETS \(n) but \(rows.count) sets")
        }
        return CGATSFile(fileType: fileType, keywords: keywords, fields: fields, rows: rows)
    }

    /// Whitespace-separated tokens; double quotes group (and are removed); `#` outside quotes ends the line.
    static func tokenize(_ line: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var quoted = false
        for ch in line {
            if inQuotes {
                if ch == "\"" { inQuotes = false } else { current.append(ch) }
            } else if ch == "\"" {
                inQuotes = true
                quoted = true
            } else if ch == "#" {
                break
            } else if ch.isWhitespace {
                if !current.isEmpty || quoted { tokens.append(current) }
                current = ""
                quoted = false
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty || quoted { tokens.append(current) }
        return tokens
    }
}

extension ColorimeterCorrection {
    /// Parses an Argyll .ccmx: `COLOR_REP "XYZ"` and 3 sets of `XYZ_X XYZ_Y XYZ_Z`; set i is matrix row i, so the
    /// corrected XYZ = M · meter XYZ. Name from DESCRIPTOR (else DISPLAY), technology from TECHNOLOGY; `source` is nil.
    public init(ccmxText: String) throws {
        let file = try CGATS.parse(ccmxText)
        guard file.fileType == "CCMX" else { throw CGATSError.malformed("expected CCMX, found \(file.fileType)") }
        if let rep = file.keywords["COLOR_REP"], rep != "XYZ" { throw CGATSError.malformed("unsupported COLOR_REP \(rep)") }
        guard let x = file.column("XYZ_X"), let y = file.column("XYZ_Y"), let z = file.column("XYZ_Z"), x.count == 3 else {
            throw CGATSError.malformed("CCMX needs 3 numeric sets of XYZ_X XYZ_Y XYZ_Z")
        }
        self.init(
            name: file.keywords["DESCRIPTOR"] ?? file.keywords["DISPLAY"] ?? "CCMX",
            displayTechnology: file.keywords["TECHNOLOGY"], kind: .matrix((0..<3).flatMap { [x[$0], y[$0], z[$0]] }))
    }

    /// Parses an Argyll .ccss: `SPEC_nnn` fields (wavelength in nm, rounded to an integer by Argyll) give one display
    /// spectrum per set. Start and step come from SPECTRAL_START_NM / SPECTRAL_END_NM when present, else from the field
    /// names. Other keywords (DISPLAY_TYPE_REFRESH, DISPLAY_TYPE_BASE_ID, ORIGINATOR …) are available via `CGATS.parse`.
    public init(ccssText: String) throws {
        let file = try CGATS.parse(ccssText)
        guard file.fileType == "CCSS" else { throw CGATSError.malformed("expected CCSS, found \(file.fileType)") }
        let bands = file.fields.indices.compactMap { i in
            file.fields[i].hasPrefix("SPEC_") ? (index: i, nm: Double(file.fields[i].dropFirst(5))) : nil
        }
        let nms = bands.compactMap(\.nm)
        guard nms.count == bands.count, nms.count >= 2 else { throw CGATSError.malformed("CCSS needs ≥ 2 numeric SPEC_ fields") }
        let start = file.keywords["SPECTRAL_START_NM"].flatMap(Double.init) ?? nms[0]
        let end = file.keywords["SPECTRAL_END_NM"].flatMap(Double.init) ?? nms[nms.count - 1]
        let step = (end - start) / Double(nms.count - 1)
        guard step > 0, nms.indices.allSatisfy({ abs(nms[$0] - (start + Double($0) * step)) <= 0.51 }) else {
            throw CGATSError.malformed("CCSS spectral fields are not evenly spaced")
        }
        let rows = try file.rows.map { row in
            try bands.map { band in
                guard let v = Double(row[band.index]) else { throw CGATSError.malformed("non-numeric value \(row[band.index])") }
                return v
            }
        }
        guard !rows.isEmpty else { throw CGATSError.missingData }
        self.init(
            name: file.keywords["DESCRIPTOR"] ?? file.keywords["DISPLAY"] ?? "CCSS",
            displayTechnology: file.keywords["TECHNOLOGY"],
            kind: .spectral(SpectralSamples(startWavelength: start, step: step, rows: rows)))
    }
}
