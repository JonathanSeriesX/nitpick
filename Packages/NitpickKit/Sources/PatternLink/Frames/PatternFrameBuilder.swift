import ColorScience
import CoreMedia
import CoreVideo
import Foundation

/// One pattern frame, ready to wrap in a `CMSampleBuffer` for `AVSampleBufferDisplayLayer`.
public struct PatternFrame {
  public let pixelBuffer: CVPixelBuffer
  /// `[R', G', B', Y', Cb, Cr]` of the centre colour in the spec's bit depth (the buffer holds them shifted to 10 bits),
  /// or nil when the pattern has no single centre colour (ramps, bars).
  public let centerCodes: [Int]?
  /// Made from the buffer after its attachments are set, so its extensions carry the same colour tags.
  public let formatDescription: CMVideoFormatDescription
}

public enum PatternFrameError: LocalizedError, Equatable {
  case invalidSize(width: Int, height: Int)
  case invalidPattern(String)
  case coreVideo(CVReturn)

  public var errorDescription: String? {
    switch self {
    case .invalidSize(let width, let height):
      "Frame size \(width)×\(height) must be even and at least 2×2"
    case .invalidPattern(let reason): reason
    case .coreVideo(let status): "CoreVideo error \(status)"
    }
  }
}

/// Draws a `PatternSpec` into an IOSurface-backed 10-bit 4:2:0 bi-planar Y'CbCr buffer:
/// `'x420'` for limited range, `'xf20'` for full range.
///
/// Memory layout (CVPixelBuffer.h, "10 bits in the MSBs of 16bits"; same as Microsoft P010): every sample is a
/// little-endian `UInt16` holding `code << 6`. Plane 0 is Y' per pixel. Plane 1 is interleaved Cb, Cr (Cb first) at
/// half width and half height. A spec with 8-bit depth lands on the 8-bit grid: stored code = code8 << 2.
/// Colour conversion is `ColorScience.YCbCr.encode`, the same code the Mac uses, so both sides agree on every code.
public final class PatternFrameBuilder {
  private struct PoolKey: Equatable {
    var width: Int
    var height: Int
    var pixelFormat: OSType
  }

  private var pool: (key: PoolKey, pool: CVPixelBufferPool)?

  public init() {}

  /// Builds one frame. `width` and `height` must be even (4:2:0 chroma).
  public func makeFrame(_ spec: PatternSpec, width: Int, height: Int) throws -> PatternFrame {
    guard width >= 2, height >= 2, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
      throw PatternFrameError.invalidSize(width: width, height: height)
    }
    let bands = try Self.layout(spec.content, width: width, height: height)
    let pixelFormat =
      spec.format.range == .limited
      ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      : kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    let buffer = try makeBuffer(PoolKey(width: width, height: height, pixelFormat: pixelFormat))
    Self.fill(buffer, bands: bands, format: spec.format, width: width)
    Self.attach(spec, to: buffer)
    let description = try CMVideoFormatDescription(imageBuffer: buffer)
    let centerCodes = spec.content.centerColor.map { color -> [Int] in
      let rgb = color.codes(in: spec.format)
      let ycc = YCbCr.encode(color, format: spec.format)
      return [rgb.r, rgb.g, rgb.b, ycc.y, ycc.cb, ycc.cr]
    }
    return PatternFrame(
      pixelBuffer: buffer, centerCodes: centerCodes, formatDescription: description)
  }

  // MARK: - HDR10 static metadata

  /// `kCVImageBufferMasteringDisplayColorVolumeKey` payload: 24 bytes, big-endian (HEVC D.2.28 / SMPTE ST 2086).
  /// Primaries G, B, R then white point as u16 in 0.00002 units; max and min luminance as u32 in 0.0001 cd/m².
  public static func masteringDisplayData(_ metadata: HDR10StaticMetadata) -> Data {
    var data = Data()
    for point in [metadata.green, metadata.blue, metadata.red, metadata.white] {
      data.appendBigEndian(UInt16(clamping: Int((point.x * 50_000).rounded())))
      data.appendBigEndian(UInt16(clamping: Int((point.y * 50_000).rounded())))
    }
    data.appendBigEndian(UInt32(clamping: Int((metadata.maxMasteringLuminance * 10_000).rounded())))
    data.appendBigEndian(UInt32(clamping: Int((metadata.minMasteringLuminance * 10_000).rounded())))
    return data
  }

  /// `kCVImageBufferContentLightLevelInfoKey` payload: 4 bytes, big-endian u16 MaxCLL then u16 MaxFALL (cd/m²).
  public static func contentLightLevelData(_ metadata: HDR10StaticMetadata) -> Data {
    var data = Data()
    data.appendBigEndian(UInt16(clamping: metadata.maxContentLightLevel))
    data.appendBigEndian(UInt16(clamping: metadata.maxFrameAverageLightLevel))
    return data
  }

  // MARK: - Layout

  /// Rows `y0..<y1` that all look the same, as horizontal spans `x0..<x1` of one colour. All edges are even.
  struct Band {
    var y0: Int
    var y1: Int
    var spans: [(x0: Int, x1: Int, color: SignalRGB)]
  }

  static func layout(_ content: PatternContent, width: Int, height: Int) throws -> [Band] {
    func uniform(_ y0: Int, _ y1: Int, _ color: SignalRGB) -> Band {
      Band(y0: y0, y1: y1, spans: [(0, width, color)])
    }
    let bands: [Band]
    switch content {
    case .black:
      bands = [uniform(0, height, .black)]
    case .fullField(let color):
      bands = [uniform(0, height, color)]
    case .window(let patch, let window, let background):
      let r = window.pixelRect(width: width, height: height)
      bands = [
        uniform(0, r.y, background),
        Band(
          y0: r.y, y1: r.y + r.height,
          spans: [
            (0, r.x, background), (r.x, r.x + r.width, patch), (r.x + r.width, width, background),
          ]),
        uniform(r.y + r.height, height, background),
      ]
    case .ramp(let steps, let from, let to, let horizontal):
      let extent = horizontal ? width : height
      guard steps >= 1, steps <= extent / 2 else {
        throw PatternFrameError.invalidPattern("Ramp needs 1…\(extent / 2) steps, got \(steps)")
      }
      let edges = (0...steps).map { $0 == steps ? extent : ($0 * extent / steps) & ~1 }
      let colors = (0..<steps).map { i in
        let t = steps == 1 ? 0 : Double(i) / Double(steps - 1)
        return SignalRGB(
          r: from.r + (to.r - from.r) * t, g: from.g + (to.g - from.g) * t,
          b: from.b + (to.b - from.b) * t)
      }
      bands =
        horizontal
        ? [
          Band(y0: 0, y1: height, spans: (0..<steps).map { (edges[$0], edges[$0 + 1], colors[$0]) })
        ]
        : (0..<steps).map { uniform(edges[$0], edges[$0 + 1], colors[$0]) }
    case .bars(let colors, let background):
      guard !colors.isEmpty else { return [uniform(0, height, background)] }
      // Equal bars, together at most 60 % of the width, each at least 2 px.
      let barWidth = max(2, (width * 6 / 10 / colors.count) & ~1)
      let total = barWidth * colors.count
      guard total <= width else {
        throw PatternFrameError.invalidPattern("\(colors.count) bars do not fit in \(width) px")
      }
      let x0 = ((width - total) / 2) & ~1
      // Middle half of the height: keeps the lit area (and OLED power limiting) down for HDR clipping bars.
      let y0 = (height / 4) & ~1
      var spans = [(x0: 0, x1: x0, color: background)]
      for (i, color) in colors.enumerated() {
        spans.append((x0 + i * barWidth, x0 + (i + 1) * barWidth, color))
      }
      spans.append((x0 + total, width, background))
      bands = [
        uniform(0, y0, background), Band(y0: y0, y1: height - y0, spans: spans),
        uniform(height - y0, height, background),
      ]
    }
    return bands.filter { $0.y1 > $0.y0 }
  }

  // MARK: - Pixels

  private func makeBuffer(_ key: PoolKey) throws -> CVPixelBuffer {
    if pool?.key != key {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: key.pixelFormat,
        kCVPixelBufferWidthKey: key.width,
        kCVPixelBufferHeightKey: key.height,
        kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
      ]
      var created: CVPixelBufferPool?
      let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
      guard status == kCVReturnSuccess, let created else {
        throw PatternFrameError.coreVideo(status)
      }
      pool = (key, created)
    }
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool!.pool, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw PatternFrameError.coreVideo(status) }
    return buffer
  }

  /// Writes each band's first row with `memset_pattern4`, then copies it down the band. No per-pixel Swift code.
  private static func fill(_ buffer: CVPixelBuffer, bands: [Band], format: SignalFormat, width: Int)
  {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let shift = 16 - format.bitDepth.rawValue
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
    let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    let rowBytes = width * 2  // luma: 2 bytes per pixel; chroma: 4 bytes per 2 pixels
    for band in bands {
      let lumaRow = luma + band.y0 * lumaStride
      let chromaRow = chroma + band.y0 / 2 * chromaStride
      for span in band.spans where span.x1 > span.x0 {
        let codes = YCbCr.encode(span.color, format: format)
        var y = UInt32(codes.y << shift) * 0x1_0001
        var cbcr = UInt32(codes.cb << shift) | UInt32(codes.cr << shift) << 16
        memset_pattern4(lumaRow + span.x0 * 2, &y, (span.x1 - span.x0) * 2)
        memset_pattern4(chromaRow + span.x0 * 2, &cbcr, (span.x1 - span.x0) * 2)
      }
      for row in (band.y0 + 1)..<band.y1 { memcpy(luma + row * lumaStride, lumaRow, rowBytes) }
      for row in (band.y0 / 2 + 1)..<(band.y1 / 2) {
        memcpy(chroma + row * chromaStride, chromaRow, rowBytes)
      }
    }
  }

  /// Colour tags must be on the buffer before the format description is made from it (CMSampleBuffer.h).
  private static func attach(_ spec: PatternSpec, to buffer: CVPixelBuffer) {
    func set(_ key: CFString, _ value: CFTypeRef) {
      CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
    }
    let bt2020 = spec.format.colorimetry == .bt2020
    set(
      kCVImageBufferColorPrimariesKey,
      bt2020 ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2)
    set(
      kCVImageBufferYCbCrMatrixKey,
      bt2020 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    let transfer: CFString =
      switch spec.format.transfer {
      case .bt1886: kCVImageBufferTransferFunction_ITU_R_709_2
      case .pq: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
      case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
      }
    set(kCVImageBufferTransferFunctionKey, transfer)
    set(kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left)
    if spec.format.transfer == .pq, let metadata = spec.hdr10Metadata {
      set(kCVImageBufferMasteringDisplayColorVolumeKey, masteringDisplayData(metadata) as CFData)
      set(kCVImageBufferContentLightLevelInfoKey, contentLightLevelData(metadata) as CFData)
    } else {
      // Pool buffers keep the attachments of their previous use.
      CVBufferRemoveAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey)
      CVBufferRemoveAttachment(buffer, kCVImageBufferContentLightLevelInfoKey)
    }
  }
}

extension Data {
  fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
