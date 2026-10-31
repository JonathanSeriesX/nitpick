import ColorScience
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import PatternLink

/// Raw stored 16-bit words, read byte by byte so the test pins the byte order too.
private struct Planes {
    let buffer: CVPixelBuffer

    func luma(_ x: Int, _ y: Int) -> UInt16 { word(plane: 0, offset: y * stride(0) + x * 2) }
    /// Cb, Cr of the 2×2 block that holds pixel (x, y).
    func chroma(_ x: Int, _ y: Int) -> (cb: UInt16, cr: UInt16) {
        let offset = y / 2 * stride(1) + x / 2 * 4
        return (word(plane: 1, offset: offset), word(plane: 1, offset: offset + 2))
    }
    func bytes(plane: Int, offset: Int, count: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(
            to: UInt8.self)
        return Array(UnsafeBufferPointer(start: base + offset, count: count))
    }

    private func stride(_ plane: Int) -> Int { CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) }
    private func word(plane: Int, offset: Int) -> UInt16 {
        let b = bytes(plane: plane, offset: offset, count: 2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }
}

private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> CFTypeRef? {
    CVBufferCopyAttachment(buffer, key, nil)
}
private func ext(_ frame: PatternFrame, _ key: CFString) -> CFPropertyList? {
    CMFormatDescriptionGetExtension(frame.formatDescription, extensionKey: key)
}

@Suite struct PatternFrameBuilderTests {
    let builder = PatternFrameBuilder()

    @Test func greyBitPlacementAndByteOrder() throws {
        let frame = try builder.makeFrame(
            PatternSpec(content: .fullField(.gray(0.5)), format: .sdr), width: 1920, height: 1080)
        let planes = Planes(buffer: frame.pixelBuffer)
        #expect(
            CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil)
        // 64 + 0.5 · 876 = 502 → 502 << 6 = 0x7D80, stored little-endian: 0x80 0x7D. Chroma 512 << 6 = 0x8000.
        #expect(planes.bytes(plane: 0, offset: 0, count: 4) == [0x80, 0x7D, 0x80, 0x7D])
        #expect(planes.bytes(plane: 1, offset: 0, count: 4) == [0x00, 0x80, 0x00, 0x80])
        for (x, y) in [(0, 0), (1919, 0), (0, 1079), (1919, 1079), (960, 540), (333, 777), (1501, 3)] {
            #expect(planes.luma(x, y) == 502 << 6)
            #expect(planes.chroma(x, y) == (512 << 6, 512 << 6))
        }
        #expect(frame.centerCodes == [502, 502, 502, 502, 512, 512])

        let full = try builder.makeFrame(
            PatternSpec(
                content: .fullField(.gray(0.5)),
                format: SignalFormat(colorimetry: .bt709, transfer: .bt1886, range: .full)),
            width: 64, height: 64)
        #expect(
            CVPixelBufferGetPixelFormatType(full.pixelBuffer)
                == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        #expect(Planes(buffer: full.pixelBuffer).luma(10, 10) == 512 << 6)  // 0.5 · 1023 = 511.5 → 512

        // 8-bit grid: 16 + 0.5 · 219 = 125.5 → 126, stored as 126 << 2 in the 10-bit buffer.
        let eight = try builder.makeFrame(
            PatternSpec(
                content: .fullField(.gray(0.5)),
                format: SignalFormat(colorimetry: .bt709, transfer: .bt1886, bitDepth: .eight)),
            width: 64, height: 64)
        #expect(Planes(buffer: eight.pixelBuffer).luma(10, 10) == (126 << 2) << 6)
        #expect(eight.centerCodes == [126, 126, 126, 126, 128, 128])
    }

    @Test func tenPercentWindowGeometry() throws {
        let patch = SignalRGB(r: 0.75, g: 0.25, b: 0.25)
        let spec = PatternSpec.patch(patch, window: .tenPercent, format: .sdr)
        let frame = try builder.makeFrame(spec, width: 3840, height: 2160)
        let planes = Planes(buffer: frame.pixelBuffer)
        let codes = YCbCr.encode(patch, format: .sdr)
        let patchY = UInt16(codes.y << 6)

        let row = (0..<3840).filter { planes.luma($0, 1080) == patchY }
        let column = (0..<2160).filter { planes.luma(1920, $0) == patchY }
        let x = try #require(row.first)
        let width = row.count
        let y = try #require(column.first)
        let height = column.count
        #expect(row.last == x + width - 1 && column.last == y + height - 1)  // one contiguous run each
        #expect((x, y, width, height) == (1312, 738, 1214, 682))
        #expect([x, y, width, height].allSatisfy { $0.isMultiple(of: 2) })
        #expect(abs(Double(width * height) / Double(3840 * 2160) - 0.10) < 0.001)
        #expect(abs(x - (3840 - x - width)) <= 2 && abs(y - (2160 - y - height)) <= 2)

        // Chroma covers exactly the window's 2×2 blocks.
        let inside = (UInt16(codes.cb << 6), UInt16(codes.cr << 6))
        let outside: (UInt16, UInt16) = (512 << 6, 512 << 6)
        #expect(planes.chroma(x, y) == inside && planes.chroma(x + width - 1, y + height - 1) == inside)
        #expect(planes.chroma(x - 1, y) == outside && planes.chroma(x + width, y) == outside)
        #expect(planes.chroma(x, y - 1) == outside && planes.chroma(x, y + height) == outside)
        #expect(planes.luma(0, 0) == 64 << 6)
        #expect(frame.centerCodes?.count == 6 && frame.centerCodes?[3] == codes.y)
    }

    @Test func fullFieldHDR10() throws {
        let signal = PQ.inverseEOTF(100)
        let frame = try builder.makeFrame(
            PatternSpec(content: .fullField(.gray(signal)), format: .hdr10, hdr10Metadata: .p3D65_1000),
            width: 1920, height: 1080)
        let planes = Planes(buffer: frame.pixelBuffer)
        let code = SignalFormat.hdr10.code(forSignal: signal)
        #expect(code == 509)  // PQ 100 cd/m² ≈ 0.5081 → 64 + 0.5081 · 876
        for (x, y) in [(0, 0), (1919, 1079), (960, 540), (17, 1001)] {
            #expect(planes.luma(x, y) == UInt16(code << 6))
            #expect(planes.chroma(x, y) == (512 << 6, 512 << 6))
        }
    }

    @Test func hdr10MetadataBytes() {
        let mdcv = PatternFrameBuilder.masteringDisplayData(.p3D65_1000)
        // G(13250, 34500) B(7500, 3000) R(34000, 16000) WP(15635, 16450) Lmax 1000 cd/m² = 10 000 000, Lmin 0.0001 = 1
        #expect(
            [UInt8](mdcv) == [
                0x33, 0xC2, 0x86, 0xC4, 0x1D, 0x4C, 0x0B, 0xB8, 0x84, 0xD0, 0x3E, 0x80, 0x3D, 0x13, 0x40,
                0x42,
                0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x01,
            ])
        #expect(
            [UInt8](PatternFrameBuilder.contentLightLevelData(.p3D65_1000)) == [0x03, 0xE8, 0x01, 0x90])  // 1000, 400
    }

    /// Absurd numbers survive JSON, so the TV must render (clamped) instead of trapping in an Int conversion.
    @Test func malformedWireValuesAreClampedNotFatal() throws {
        let huge = HDR10StaticMetadata(
            red: Chromaticity(x: 1e300, y: -1e300), green: .d65, blue: .d65, maxMasteringLuminance: 1e300,
            minMasteringLuminance: -1)
        let sent = PatternSpec.patch(
            SignalRGB(r: 1e300, g: -1e300, b: 0.5), window: WindowSpec(areaFraction: 1e300, centerX: 1e300, centerY: -1e300),
            format: .hdr10, hdr10Metadata: huge)
        guard
            case .show(_, let spec) = try LinkCodec.decode(
                ClientMessage.self, from: LinkCodec.encode(ClientMessage.show(sequence: 1, pattern: sent)))
        else {
            Issue.record("not a show")
            return
        }
        let frame = try builder.makeFrame(spec, width: 1920, height: 1080)
        #expect(frame.centerCodes?.allSatisfy { SignalFormat.hdr10.legalCodes.contains($0) } == true)
        let corner = WindowSpec(areaFraction: 0.1, centerX: 1e300, centerY: -1e300).pixelRect(width: 1920, height: 1080)
        #expect(corner.x + corner.width == 1920 && corner.y == 0, "clamped to the top-right corner")
        let mdcv = [UInt8](PatternFrameBuilder.masteringDisplayData(huge))
        #expect(mdcv[8...11] == [0xFF, 0xFF, 0x00, 0x00] && mdcv[16...] == [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0])
    }

    @Test func formatDescriptionCarriesColourTags() throws {
        let sdr = try builder.makeFrame(.black(format: .sdr), width: 1920, height: 1080)
        #expect(
            CMFormatDescriptionGetMediaSubType(sdr.formatDescription)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(
            ext(sdr, kCMFormatDescriptionExtension_ColorPrimaries) as? String
                == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(
            ext(sdr, kCMFormatDescriptionExtension_TransferFunction) as? String
                == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        #expect(
            ext(sdr, kCMFormatDescriptionExtension_YCbCrMatrix) as? String
                == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)

        let hdr = try builder.makeFrame(
            PatternSpec(content: .black, format: .hdr10, hdr10Metadata: .p3D65_1000), width: 1920,
            height: 1080)
        #expect(
            ext(hdr, kCMFormatDescriptionExtension_ColorPrimaries) as? String
                == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(
            ext(hdr, kCMFormatDescriptionExtension_TransferFunction) as? String
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(
            ext(hdr, kCMFormatDescriptionExtension_YCbCrMatrix) as? String
                == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        #expect(
            ext(hdr, kCMFormatDescriptionExtension_MasteringDisplayColorVolume) as? Data
                == PatternFrameBuilder.masteringDisplayData(.p3D65_1000))
        #expect(
            ext(hdr, kCMFormatDescriptionExtension_ContentLightLevelInfo) as? Data
                == PatternFrameBuilder.contentLightLevelData(.p3D65_1000))

        let hlg = try builder.makeFrame(.black(format: .hlg), width: 1920, height: 1080)
        #expect(
            ext(hlg, kCMFormatDescriptionExtension_TransferFunction) as? String
                == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    @Test func hdrMetadataOnlyOnPQBuffers() throws {
        let hdr = try builder.makeFrame(
            PatternSpec(content: .black, format: .hdr10, hdr10Metadata: .p3D65_1000), width: 256,
            height: 128)
        #expect(
            attachment(hdr.pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey) as? Data
                == PatternFrameBuilder.masteringDisplayData(.p3D65_1000))
        #expect(
            attachment(hdr.pixelBuffer, kCVImageBufferContentLightLevelInfoKey) as? Data
                == PatternFrameBuilder.contentLightLevelData(.p3D65_1000))
        #expect(
            attachment(hdr.pixelBuffer, kCVImageBufferChromaLocationTopFieldKey) as? String
                == kCVImageBufferChromaLocation_Left as String)
        // Same size and pixel format, so the pool hands back recycled HDR buffers: their metadata must be gone.
        for _ in 0..<4 {
            let sdr = try builder.makeFrame(
                PatternSpec(content: .black, format: .sdr, hdr10Metadata: .p3D65_1000), width: 256,
                height: 128)
            #expect(attachment(sdr.pixelBuffer, kCVImageBufferMasteringDisplayColorVolumeKey) == nil)
            #expect(attachment(sdr.pixelBuffer, kCVImageBufferContentLightLevelInfoKey) == nil)
            #expect(
                attachment(sdr.pixelBuffer, kCVImageBufferTransferFunctionKey) as? String
                    == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        }
    }

    @Test func rampAndBars() throws {
        let ramp = try builder.makeFrame(
            PatternSpec(
                content: .ramp(steps: 21, from: .black, to: .white, horizontal: true), format: .sdr),
            width: 1920, height: 1080)
        let rampPlanes = Planes(buffer: ramp.pixelBuffer)
        // Bar i spans [i·1920/21 & ~1, (i+1)·1920/21 & ~1); sample each bar's middle.
        let lumaCodes = (0..<21).map { i in
            Int(rampPlanes.luma(((i * 1920 / 21) + ((i + 1) * 1920 / 21)) / 2, 540) >> 6)
        }
        #expect(lumaCodes == (0..<21).map { SignalFormat.sdr.code(forSignal: Double($0) / 20) })
        #expect(lumaCodes.first == 64 && lumaCodes[10] == 502 && lumaCodes.last == 940)
        #expect(ramp.centerCodes == nil)

        let vertical = try builder.makeFrame(
            PatternSpec(
                content: .ramp(steps: 2, from: .black, to: .white, horizontal: false), format: .sdr),
            width: 64, height: 64)
        #expect(
            Planes(buffer: vertical.pixelBuffer).luma(5, 10) == 64 << 6
                && Planes(buffer: vertical.pixelBuffer).luma(5, 50) == 940 << 6)

        let colors = (0..<8).map { SignalRGB.gray(0.9 + 0.025 * Double($0)) }
        let bars = try builder.makeFrame(
            PatternSpec(content: .bars(colors, background: .black), format: .sdr), width: 1920,
            height: 1080)
        let barPlanes = Planes(buffer: bars.pixelBuffer)
        let lit = (0..<1920).filter { barPlanes.luma($0, 540) != 64 << 6 }
        let left = try #require(lit.first)
        let total = lit.count
        #expect(lit.last == left + total - 1 && total <= 1920 * 6 / 10 && total.isMultiple(of: 8))
        #expect(abs(left - (1920 - left - total)) <= 2)
        let barCodes = (0..<8).map { Int(barPlanes.luma(left + $0 * total / 8 + total / 16, 540) >> 6) }
        #expect(barCodes == colors.map { SignalFormat.sdr.code(forSignal: $0.g) })
        #expect(barPlanes.luma(960, 10) == 64 << 6)  // background above the bars

        #expect(throws: PatternFrameError.invalidSize(width: 1919, height: 1080)) {
            try builder.makeFrame(.black(format: .sdr), width: 1919, height: 1080)
        }
    }

    @Test func uhdFrameBuildTime() throws {
        let spec = PatternSpec.patch(.gray(0.5), format: .hdr10, hdr10Metadata: .p3D65_1000)
        _ = try builder.makeFrame(spec, width: 3840, height: 2160)  // creates the pool
        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<5 {
            let start = clock.now
            _ = try builder.makeFrame(spec, width: 3840, height: 2160)
            times.append(clock.now - start)
        }
        let median = times.sorted()[2]
        print("3840×2160 frame build: median \(median), all \(times)")
        #expect(median < .milliseconds(200))
    }
}
