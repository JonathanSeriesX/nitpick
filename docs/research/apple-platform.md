# Apple platform research: tvOS pattern generator and macOS controller

Researched 2026-10-31. Toolchain on this machine: Xcode 27.1 (27A9275), Swift 6.4, SDKs `AppleTVOS27.0.sdk` and `MacOSX27.0.sdk`.
Target hardware: Apple TV 4K (1st generation, 2017, A10X).

Path abbreviations used in citations:

- `TV/` = `/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS27.0.sdk/System/Library/Frameworks/`
- `TVSWIFT/` = `/Applications/Xcode.app/Contents/Developer/Platforms/AppleTVOS.platform/Developer/SDKs/AppleTVOS27.0.sdk/usr/lib/swift/`
- `MAC/` = `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk/System/Library/Frameworks/`

Availability rule: when a header says `API_AVAILABLE(ios(N))` and has no `tvos(...)` entry, clang infers tvOS N availability. Such rows are marked "(inferred)".

## 0. Read this first

1. **The 1st-gen Apple TV 4K stops at tvOS 26.** tvOS 27 supports the Apple TV 4K (2nd generation) and later only ([MacRumors, 2026-09-15](https://www.macrumors.com/2026/09/15/tvos-27-compatible-apple-tv-models/)). Keep `TVOS_DEPLOYMENT_TARGET` at 26.x or lower. Do not use APIs marked `tvos(27.0)` (for example the Swift `AVSampleBufferVideoRenderer.Receiver` API, `TVSWIFT/AVFoundation.swiftmodule/arm64-apple-tvos.swiftinterface:1453-1477`).
2. **`AVDisplayCriteria.init(refreshRate:videoDynamicRange:)` is not in the SDK.** The only initializer is `init(refreshRate:formatDescription:)`, tvOS 17.0 (`TV/AVFoundation.framework/Headers/AVDisplayCriteria.h`). The `videoDynamicRange` initializer is private. Kodi declares it in its own category ([Kodi TVOSDisplayManager.mm](https://github.com/xbmc/xbmc/blob/master/xbmc/platform/darwin/tvos/TVOSDisplayManager.mm)). Guideline 2.5.1 forbids private API.
3. **`AVPlayer.HDRMode` is deprecated in tvOS 26.** Values: `.hlg = 0x1`, `.hdr10 = 0x2`, `.dolbyVision = 0x4`. `availableHDRModes` is deprecated too. The replacement is `AVPlayer.eligibleForHDRPlayback` (Bool, not KVO-observable) (`TV/AVFoundation.framework/Headers/AVPlayer.h:663-694`).
4. **The CAMetalLayer HDR path does not exist on tvOS.** `CAMetalLayer.wantsExtendedDynamicRangeContent`, `CAMetalLayer.EDRMetadata` and the class `CAEDRMetadata` are `API_UNAVAILABLE(tvos)` (`TV/QuartzCore.framework/Headers/CAMetalLayer.h:128-138`, `CAEDRMetadata.h:15`).
5. **Apple documents the path this product needs.** From the `AVDisplayCriteria` reference: "If your app doesn't use AVAsset, such as a streaming app that renders sample buffers using AVSampleBufferDisplayLayer, you can manually create an instance using the init(refreshRate:formatDescription:) initializer" ([AVDisplayCriteria](https://developer.apple.com/documentation/avfoundation/avdisplaycriteria)).
6. **No public API reports the current HDMI dynamic range** (SDR, HDR10 or Dolby Vision) ([forum 830876](https://developer.apple.com/forums/thread/830876)). The app can request a mode. It cannot read back what the TV receives.
7. **No public API produces Dolby Vision from app-generated pixels.** Dolby Vision output comes only from Dolby-Vision-encoded media, or from the user setting Video Format to Dolby Vision (section 3).
8. **tvOS has no local network privacy prompt. macOS 15 and later has one** ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
9. **Nobody has shown that the Apple TV is bit-exact.** One calibration-forum participant states: "ATV is not bit-perfect and it will never be bit-perfect for patch generation" ([Light Illusion forum](https://lightillusion.com/forums/display-calibration-8/apple-tv-4k-yr.-2021-bit-perfect-861.html)). That claim concerns UI-drawn patches. The video-layer path below is our best chance, but it must be verified on hardware with an HDMI capture device.

## 1. tvOS HDMI output control

### 1.1 API surface (tvOS 27 SDK headers)

| Symbol                                                                                                                                      | tvOS availability                 | Source                                                                                                                      |
| ------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `UIWindow.avDisplayManager`                                                                                                                 | 11.2                              | `TV/AVKit.framework/Headers/UIWindow.h:25-27`                                                                               |
| `AVDisplayManager.preferredDisplayCriteria` (copy, nullable)                                                                                | 11.2                              | `TV/AVKit.framework/Headers/AVDisplayManager.h`                                                                             |
| `AVDisplayManager.isDisplayModeSwitchInProgress` ("This property is observable")                                                            | 11.2                              | same                                                                                                                        |
| `AVDisplayManager.isDisplayCriteriaMatchingEnabled`                                                                                         | 11.3                              | same                                                                                                                        |
| `AVDisplayManagerModeSwitchStartNotification`, `...EndNotification`, `...SettingsChangedNotification`                                       | 11.3                              | same                                                                                                                        |
| `AVDisplayCriteria` (`AV_INIT_UNAVAILABLE`, `NS_SWIFT_SENDABLE`, unavailable on iOS/macOS)                                                  | 11.2                              | `TV/AVFoundation.framework/Headers/AVDisplayCriteria.h`                                                                     |
| `AVDisplayCriteria(refreshRate: Float, formatDescription: CMFormatDescription)`                                                             | 17.0                              | same                                                                                                                        |
| `AVAsset.preferredDisplayCriteria`: synchronous getter deprecated in Swift (tvOS 16); use `try await asset.load(.preferredDisplayCriteria)` | 11.2                              | `TV/AVFoundation.framework/Headers/AVAsset.h:91-93`, `TVSWIFT/AVFoundation.swiftmodule/arm64-apple-tvos.swiftinterface:529` |
| `AVPlayerViewController.appliesPreferredDisplayCriteriaAutomatically`                                                                       | 11.2                              | `TV/AVKit.framework/Headers/AVPlayerViewController.h:167`                                                                   |
| `AVPlayer.HDRMode`, `AVPlayer.availableHDRModes`                                                                                            | 11.2, deprecated 26.0             | `TV/AVFoundation.framework/Headers/AVPlayer.h:663-683`                                                                      |
| `AVPlayer.eligibleForHDRPlayback`, `AVPlayerEligibleForHDRPlaybackDidChangeNotification`                                                    | 13.4                              | `AVPlayer.h:688-694`                                                                                                        |
| `UIScreen.currentEDRHeadroom`, `UIScreen.potentialEDRHeadroom`                                                                              | 16.0 (inferred, `ios(16.0)` only) | `TV/UIKit.framework/Headers/UIScreen.h:100-103`                                                                             |
| `UITraitCollection.displayGamut` (`.SRGB`, `.P3`)                                                                                           | 10.0 (inferred)                   | `TV/UIKit.framework/Headers/UITraitCollection.h:63`, `UIInterface.h:50-54`                                                  |
| `UIScreen.currentMode`, `nativeBounds`, `nativeScale`, `maximumFramesPerSecond`                                                             | inferred                          | `UIScreen.h:65-87`                                                                                                          |
| `UIScreen.availableModes`, `UIScreen.preferredMode`                                                                                         | `API_UNAVAILABLE(tvos)`           | `UIScreen.h:62-63`                                                                                                          |

### 1.2 How to request a mode

Build the criteria from the same format description as the pixel buffers you display:

```swift
// tvOS 17+. pixelBuffer already carries its colour attachments (section 2.1).
let fd = try CMVideoFormatDescription(imageBuffer: pixelBuffer)
let dm = window.avDisplayManager  // key window of the active UIWindowScene
dm.preferredDisplayCriteria = AVDisplayCriteria(
    refreshRate: Float(window.screen.maximumFramesPerSecond), formatDescription: fd)
```

- `CMVideoFormatDescription(imageBuffer:)` exists in the CoreMedia Swift overlay, tvOS 13 (`TV/CoreMedia.framework/Modules/CoreMedia.swiftmodule/arm64-apple-tvos.swiftinterface:589-592`). It equals `CMVideoFormatDescriptionCreateForImageBuffer`. That function copies these buffer attachments into the extensions: ColorPrimaries, TransferFunction, YCbCrMatrix, MasteringDisplayColorVolume and ContentLightLevelInfo (`TV/CoreMedia.framework/Headers/CMFormatDescription.h:1210-1227`, list at `:1395-1410`).
- Hardware evidence: KSPlayer passed an `'x420'` format description with `ITU_R_2020` primaries and `SMPTE_ST_2084_PQ` transfer. An Apple TV 4K (3rd gen, tvOS 17) switched to HDR10 ([KSPlayer #633](https://github.com/kingslay/KSPlayer/issues/633)). The same log shows `CMVideoFormatDescriptionCreate` error -12710 on a hand-built description. Build the description from a real pixel buffer.
- SDR patterns: set criteria built from a BT.709-tagged buffer. Do not set `nil`. `nil` means "a display mode that is suitable for a wide range of video and non-video content" (AVDisplayManager.h). That is the user's Video Format, which may be HDR10 or Dolby Vision.
- Order: the tech talk says to "perform this switch before assigning the AVPlayerItem" ([Tech Talk 503](https://developer.apple.com/videos/play/tech-talks/503/)). For us: set criteria, wait for the switch to end, then enqueue the patch.
- Get the manager from the key window: "Don't directly instantiate a display manager object. Instead, access the current instance from the key window's avDisplayManager property" ([AVDisplayManager](https://developer.apple.com/documentation/avkit/avdisplaymanager)).
- Fallback source of criteria (tvOS 11.2+, public, the "older trick"): bundle two 1-second HEVC Main10 clips (BT.709 SDR and BT.2020 PQ). Get criteria with `try await AVURLAsset(url:).load(.preferredDisplayCriteria)`. Use this if `init(refreshRate:formatDescription:)` misbehaves on the 1st-gen box.
- Private initializer values, for reference only (do not ship): Kodi passes `videoDynamicRange` SDR = 0/1, HDR10 = 2/3, Dolby Vision = 4 ([Kodi](https://github.com/xbmc/xbmc/blob/master/xbmc/platform/darwin/tvos/TVOSDisplayManager.mm)).

### 1.3 When the user has matching off

- The header says `preferredDisplayCriteria` "will only be honored when user settings allow it". Nothing fails. The output stays at Settings > Video and Audio > Format.
- Both Match Content options are off by default ([Tech Talk 503](https://developer.apple.com/videos/play/tech-talks/503/)). Path: Settings > Video and Audio > Match Content > Match Dynamic Range / Match Frame Rate ([Apple 102277](https://support.apple.com/en-us/102277)).
- When `isDisplayCriteriaMatchingEnabled == false`, show the user what to do: turn on Match Dynamic Range. Listen for `AVDisplayManagerModeSwitchSettingsChangedNotification` and refresh the hint.
- `isDisplayCriteriaMatchingEnabled` is one Bool. UNCONFIRMED: whether it is true when only Match Frame Rate is on.

### 1.4 How long a mode switch takes

- Header: "The mode switch may last several seconds longer" than `displayModeSwitchInProgress` reports, and the property "is observable" (KVO).
- Tech talk: the switch "will generally cause the screen to flash or temporarily black out, and may take a few seconds to complete".
- Apple support: "You might experience a blank screen or flickering as your television switches between formats" ([Apple 102277](https://support.apple.com/en-us/102277)).
- Kodi observes `displayModeSwitchInProgress` through KVO and notes that the box "might have switched to some other rate than what we requested".
- Implementation: KVO on `isDisplayModeSwitchInProgress` plus `AVDisplayManagerModeSwitchEndNotification`, then a configurable guard delay (start at 2 s) before telling the Mac "ready". UNCONFIRMED: real durations for the user's TV. Measure them.

### 1.5 Can the app know the current output?

- No API reports the HDMI dynamic range ([forum 830876](https://developer.apple.com/forums/thread/830876)).
- `AVPlayer.eligibleForHDRPlayback` only says that an HDR display is attached and the device can play HDR (`AVPlayer.h:686-688`).
- `UIScreen.currentEDRHeadroom` compiles on tvOS (inferred availability). UNCONFIRMED: whether it changes between SDR and HDR10 output on Apple TV. Log it on hardware. If it changes, it is a cheap signal.
- `traitCollection.displayGamut` describes the UI gamut (sRGB or P3), not the HDMI mode.
- Practical check: after the switch, the Mac measures a known patch (for example PQ code 520, about 100 cd/m²) and confirms that the result fits PQ, not SDR. Also ask the user to confirm the TV's HDR badge.

### 1.6 Video Format and Match Content: expected behaviour

| User Video Format | Match Dynamic Range | App criteria      | Expected HDMI output                                                   |
| ----------------- | ------------------- | ----------------- | ---------------------------------------------------------------------- |
| 4K SDR            | on                  | HDR10 description | HDR10, if the TV supports it at that rate                              |
| 4K SDR            | off                 | HDR10 description | SDR. UNCONFIRMED: PQ buffers are probably tone-mapped to SDR.          |
| 4K HDR            | off                 | any               | HDR10. The box maps SDR UI and SDR video into PQ.                      |
| 4K Dolby Vision   | off                 | any               | Dolby Vision. The box converts all content (community reports, below). |
| 4K Dolby Vision   | on                  | SDR description   | SDR                                                                    |
| 4K Dolby Vision   | on                  | HDR10 description | HDR10                                                                  |

Sources: Apple says Match Dynamic Range makes the box "match its output to the original dynamic range of content" ([Apple 102277](https://support.apple.com/en-us/102277)). A forum answer says that with Match Dynamic Range off, the Apple TV "will use the dynamic range as set in video Format" ([Apple Community 254404318](https://discussions.apple.com/thread/254404318)). If the TV can show HDR only at 30 Hz, Apple says to turn on Match Dynamic Range ([Apple 102339](https://support.apple.com/en-us/102339)).

### 1.7 Dolby Vision output with SDR or HDR10 content

- Community reports say that with Video Format = Dolby Vision and matching off, all video is output as Dolby Vision. HDR10 content is "upconverted and not true DV" ([Firecore 34769](https://community.firecore.com/t/4k-dolby-vision-format-enabled-what-happens-to-hdr-playback/34769)). Apple does not document the conversion.
- The Apple TV uses TV-led Dolby Vision. Forum posts describe the HDMI signal as "RGB tunneling": 12-bit Dolby Vision data carried in an RGB 4:4:4 8-bit container. The TV's Dolby Vision engine decodes it ([Firecore 51228](https://community.firecore.com/t/apple-tv-not-outputting-10bit-colour-depth/51228)). UNCONFIRMED by Apple.
- Consequence: in Dolby Vision mode, app code values never reach the panel unchanged. The TV display-maps them.

### 1.8 First-generation Apple TV 4K specifics

| Item      | Value                                                                                   | Source                                                                                |
| --------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Chip      | A10X Fusion                                                                             | [Apple 111929](https://support.apple.com/en-us/111929)                                |
| HDMI      | 2.0a (18 Gbit/s)                                                                        | same                                                                                  |
| SDR video | H.264/HEVC up to 2160p, 60 fps                                                          | same                                                                                  |
| HDR video | "HEVC Dolby Vision (Profile 5)/HDR10 (Main 10 profile) up to 2160p". HLG is not listed. | same                                                                                  |
| HDR10+    | No. "HDR10+ is a supported format only on Apple TV 4K (3rd generation)."                | [Apple 102339](https://support.apple.com/en-us/102339)                                |
| QMS       | No. QMS needs HDMI 2.1 (3rd gen only).                                                  | [9to5Mac](https://9to5mac.com/2022/11/02/apple-tv-qms/)                               |
| 120 Hz    | No. The maximum is 60 fps.                                                              | [Apple 111929](https://support.apple.com/en-us/111929)                                |
| Last OS   | tvOS 26.x                                                                               | [MacRumors](https://www.macrumors.com/2026/09/15/tvos-27-compatible-apple-tv-models/) |

HDMI 2.0 bandwidth math: 4K60 at 10 bits does not fit 4:4:4. So 4K60 HDR is 4:2:2 (12-bit container) or 4:2:0. 4K60 SDR in RGB or 4:4:4 is 8-bit. Community reports agree that the Apple TV "only supports 4:2:0 and 4:2:2 for HDR" ([Firecore 60911](https://community.firecore.com/t/apple-tv-infuse-can-it-play-42-properly/60911)).

## 2. Putting exact code values on HDMI

### 2.1 (a) AVSampleBufferDisplayLayer with uncompressed 10-bit Y'CbCr (PRIMARY)

#### Availability (tvOS SDK)

| Symbol                                                                                | tvOS                                               | Source                                                                       |
| ------------------------------------------------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------- |
| `AVSampleBufferDisplayLayer`                                                          | 10.2                                               | `TV/AVFoundation.framework/Headers/AVSampleBufferDisplayLayer.h:36-37`       |
| `layer.enqueue(_:)`, `flush()`, `status` on the layer                                 | 10.2, deprecated 18.0 (use `sampleBufferRenderer`) | same, `:73-184`                                                              |
| `layer.sampleBufferRenderer` (`AVSampleBufferVideoRenderer`, `NS_SWIFT_NONSENDABLE`)  | 17.0                                               | same `:246`, `AVSampleBufferVideoRenderer.h:55-57`                           |
| `isReadyForDisplay`, `AVSampleBufferDisplayLayerReadyForDisplayDidChangeNotification` | 17.4                                               | `AVSampleBufferDisplayLayer.h:32,60`                                         |
| `renderer.copyDisplayedPixelBuffer()`                                                 | 17.4                                               | `AVSampleBufferVideoRenderer.h:213-221`                                      |
| `renderer.recommendedPixelBufferAttributes`                                           | 26.0                                               | `AVSampleBufferVideoRenderer.h:256`                                          |
| `layer.preventsDisplaySleepDuringVideoPlayback`                                       | 13.0                                               | `AVSampleBufferDisplayLayer.h:204`                                           |
| Swift `AVSampleBufferVideoRenderer.Receiver`, `enqueue`/`enqueueImmediately`          | 27.0. Do not use.                                  | `TVSWIFT/AVFoundation.swiftmodule/arm64-apple-tvos.swiftinterface:1453-1477` |

#### Pixel format and bit placement

From `TV/CoreVideo.framework/Headers/CVPixelBuffer.h:111-116`:

- `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange = 'x420'`: "2 plane YCbCr10 4:2:0, each 10 bits in the MSBs of 16bits, video-range (luma=[64,940] chroma=[64,960])".
- `kCVPixelFormatType_420YpCbCr10BiPlanarFullRange = 'xf20'`: "full-range (Y range 0-1023)".
- `'x422'`, `'x444'`, `'xf22'`, `'xf44'` also exist. UNCONFIRMED: whether the A10X display path accepts them. `'x420'` is the A10X HEVC decoder's native output, so it is the safe choice.

Memory layout:

- Plane 0: Y', one `UInt16` per pixel. Plane 1: interleaved Cb, Cr pairs at half width and half height. Cb comes first, as in the 8-bit bi-planar formats (`CVPixelBuffer.h:79`).
- Stored word = `UInt16(code) << 6`. The low 6 bits are 0.
- Byte order: the header does not say. Use native little-endian `UInt16`. This matches Microsoft P010: "little-endian WORD ... lowest 6 bits set to zero", with Cb in the low word of each pair ([Microsoft P010](https://learn.microsoft.com/en-us/windows/win32/medfound/10-bit-and-16-bit-yuv-video-formats)). Check this once with a write and read-back test.
- Rows are padded. Always use `CVPixelBufferGetBaseAddressOfPlane` and `CVPixelBufferGetBytesPerRowOfPlane`.

Narrow-range (video-range) 10-bit codes ([ITU-R BT.2100](https://www.itu.int/rec/R-REC-BT.2100), [BT.709](https://www.itu.int/rec/R-REC-BT.709)):

| Signal                                      | Code                                             |
| ------------------------------------------- | ------------------------------------------------ |
| Y' black                                    | 64                                               |
| Y' nominal peak                             | 940                                              |
| Cb, Cr range                                | 64 to 960                                        |
| Cb, Cr neutral                              | 512                                              |
| Valid range including footroom and headroom | 4 to 1019 (0 to 3 and 1020 to 1023 are reserved) |

Conversion formulas (BT.2020 non-constant luminance: Kr = 0.2627, Kb = 0.0593; BT.709: Kr = 0.2126, Kb = 0.0722):

- Y' = Kr·R' + (1 − Kr − Kb)·G' + Kb·B'
- Cb = (B' − Y') / (2(1 − Kb)), Cr = (R' − Y') / (2(1 − Kr))
- D_Y = round((219·Y' + 16)·4), D_C = round((224·C + 128)·4)

Grey patches give Cb = Cr = 512 exactly. Coloured patches cannot hit every 10-bit R'G'B' triple after the TV converts back. Expect up to about 1 code of error. If the calibration software sends R'G'B' triples, report the Y'CbCr triple actually sent.

#### Colour attachments

Set the attachments with `CVBufferSetAttachment(..., .shouldPropagate)` **before** you create the format description. The format description must match the attachments, or the sample buffer is inconsistent (`TV/CoreMedia.framework/Headers/CMSampleBuffer.h:656-684`). All keys come from `TV/CoreVideo.framework/Headers/CVImageBuffer.h`.

| Key                                                                       | HDR10 value                                                                | SDR value                                    |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------- |
| `kCVImageBufferColorPrimariesKey` (`:81-88`)                              | `kCVImageBufferColorPrimaries_ITU_R_2020`                                  | `kCVImageBufferColorPrimaries_ITU_R_709_2`   |
| `kCVImageBufferTransferFunctionKey` (`:90-101`)                           | `kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ` (HLG: `_ITU_R_2100_HLG`) | `kCVImageBufferTransferFunction_ITU_R_709_2` |
| `kCVImageBufferYCbCrMatrixKey` (`:73-79`)                                 | `kCVImageBufferYCbCrMatrix_ITU_R_2020`                                     | `kCVImageBufferYCbCrMatrix_ITU_R_709_2`      |
| `kCVImageBufferChromaLocationTopFieldKey` / `BottomFieldKey` (`:104-108`) | `kCVImageBufferChromaLocation_Left`                                        | same                                         |
| `kCVImageBufferMasteringDisplayColorVolumeKey` (`:225-226`)               | 24-byte `CFData` (below)                                                   | omit                                         |
| `kCVImageBufferContentLightLevelInfoKey` (`:228-229`)                     | 4-byte `CFData` (below)                                                    | omit                                         |

Header text: the mastering key is "CFData (24 bytes) containing big-endian data matching payload of ISO/IEC 23008-2:2015(E), D.2.28 Mastering display colour volume SEI message". The content light level key is "CFData (4 bytes) containing big-endian data matching payload of Content Light Level Information SEI message". `CAEDRMetadata.h` on macOS says the same and adds that the content light level layout is D.2.35 (`MAC/QuartzCore.framework/Headers/CAEDRMetadata.h:28-55`).

Mastering display colour volume, 24 bytes, all big-endian:

| Offset | Type | Field                           | Unit         |
| ------ | ---- | ------------------------------- | ------------ |
| 0      | u16  | display_primaries_x[0] (green)  | 0.00002      |
| 2      | u16  | display_primaries_y[0] (green)  | 0.00002      |
| 4      | u16  | display_primaries_x[1] (blue)   | 0.00002      |
| 6      | u16  | display_primaries_y[1] (blue)   | 0.00002      |
| 8      | u16  | display_primaries_x[2] (red)    | 0.00002      |
| 10     | u16  | display_primaries_y[2] (red)    | 0.00002      |
| 12     | u16  | white_point_x                   | 0.00002      |
| 14     | u16  | white_point_y                   | 0.00002      |
| 16     | u32  | max_display_mastering_luminance | 0.0001 cd/m² |
| 20     | u32  | min_display_mastering_luminance | 0.0001 cd/m² |

The order G, B, R, white point, then max and min luminance is the order x265 writes. Its example for a P3-D65 1000-nit display is `G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)` ([x265 CLI](https://x265.readthedocs.io/en/master/cli.html)). MPVKit fills these same CoreVideo keys in the same layout for `AVSampleBufferDisplayLayer` on tvOS: "big-endian; primaries G, B, R then white in 0.00002 units, luminance in 0.0001 cd/m²" ([MPVKit PR 9](https://github.com/Drvolks/MPVKit/pull/9)). BT.2020 primaries in these units: G(8500,39850), B(6550,2300), R(35400,14600), D65 white point (15635,16450).

Content light level, 4 bytes, big-endian: offset 0 `u16` MaxCLL in cd/m², offset 2 `u16` MaxFALL in cd/m². 0 means "unknown" ([x265 CLI](https://x265.readthedocs.io/en/master/cli.html)).

```swift
func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
func be32(_ v: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) } }
// BT.2020 container, 1000 / 0.005 cd/m² mastering display
let mdcv = Data(be16(8500) + be16(39850) + be16(6550) + be16(2300) + be16(35400) + be16(14600)
    + be16(15635) + be16(16450) + be32(1000 * 10_000) + be32(50))
let clli = Data(be16(1000) + be16(400))
assert(mdcv.count == 24 && clli.count == 4)
```

#### Sample buffer and enqueue

```swift
// pool: IOSurface-backed, 'x420'. On tvOS 26, merge renderer.recommendedPixelBufferAttributes
// through CVPixelBufferCreateResolvedAttributesDictionary (AVSampleBufferVideoRenderer.h:252-256).
let fd = try CMVideoFormatDescription(imageBuffer: pb)  // after the attachments are set
let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
let sb = try CMSampleBuffer(imageBuffer: pb, formatDescription: fd, sampleTiming: timing)
sb.sampleAttachments[0][.displayImmediately] = true
layer.sampleBufferRenderer.enqueue(sb)
```

- Swift overlay: `CMSampleBuffer(imageBuffer:formatDescription:sampleTiming:)` and `sampleAttachments[...][.displayImmediately]` are tvOS 13 (`CoreMedia.swiftmodule/arm64-apple-tvos.swiftinterface:2066`, `:2202`, `:2240`).
- C equivalents: `CMVideoFormatDescriptionCreateForImageBuffer` (`CMFormatDescription.h:1212`), `CMSampleBufferCreateReadyWithImageBuffer` (`CMSampleBuffer.h:658-684`), `CMSampleBufferGetSampleAttachmentsArray` plus `kCMSampleAttachmentKey_DisplayImmediately` (`CMSampleBuffer.h:1479-1518`).
- Static patterns need one enqueue per patch change. UNCONFIRMED: the layer keeps showing the last frame with no `controlTimebase` set. That is the expected behaviour.
- "On screen" check: poll `renderer.copyDisplayedPixelBuffer()` (tvOS 17.4) until it returns the buffer you enqueued. Then send the ack to the Mac. The Mac adds the TV's own settle delay.

#### Does HDR10 static metadata reach the HDMI InfoFrame?

UNCONFIRMED. The evidence conflicts:

- 2018: Apple TV output carried BT.2020, 1000/0.005 cd/m² mastering and MaxCLL/MaxFALL 4000/1000 regardless of the file. Firecore (Infuse): "these values are being set by the Apple TV and cannot be adjusted by Infuse" ([Firecore 16044](https://community.firecore.com/t/hdr-metadata-not-correct-replaced-by-standard-values/16044)).
- A later report says the box passes the content metadata when the mastering primaries are P3, and uses 4000/1000 when they are BT.2020 ([Apple Community 254507878](https://discussions.apple.com/thread/254507878)). A December 2025 question about whether tvOS 26 fixed this got no answer.
- MPVKit: PQ frames without these attachments looked "very dark" on an Apple TV 2017. Adding them was verified only in the simulator ([MPVKit PR 9](https://github.com/Drvolks/MPVKit/pull/9)).

Plan: attach the metadata anyway, read the InfoFrame with an HDFury (Vertex2, Arcana or Diva), and tell users to turn off TV dynamic tone mapping.

#### Does tvOS convert video-layer content when the mode matches?

UNCONFIRMED. No Apple document promises passthrough. One forum participant says Apple processing after the app adds error ([Light Illusion forum](https://lightillusion.com/forums/display-calibration-8/apple-tv-4k-yr.-2021-bit-perfect-861.html)). Expected best case: with HDMI Output = YCbCr, matched mode and a full-screen layer, `'x420'` narrow-range codes leave the box unchanged (4:2:2 output shifts them into the 12-bit container). Verify with a capture card (section 9).

### 2.2 (b) CAMetalLayer with EDR (tvOS: NOT AVAILABLE)

| Symbol                                                                             | tvOS                        | Source                                                     |
| ---------------------------------------------------------------------------------- | --------------------------- | ---------------------------------------------------------- |
| `CAMetalLayer.wantsExtendedDynamicRangeContent`                                    | `API_UNAVAILABLE(tvos)`     | `TV/QuartzCore.framework/Headers/CAMetalLayer.h:128-129`   |
| `CAMetalLayer.EDRMetadata`                                                         | `API_UNAVAILABLE(tvos)`     | `CAMetalLayer.h:137-138`                                   |
| `CAEDRMetadata` (including `hdr10(minLuminance:maxLuminance:opticalOutputScale:)`) | `API_UNAVAILABLE(tvos)`     | `CAEDRMetadata.h:15`                                       |
| `CALayer.wantsExtendedDynamicRangeContent`                                         | `API_UNAVAILABLE(tvos)`     | `CALayer.h:437-457`                                        |
| `CAMetalLayer.colorspace`                                                          | available (class is tvOS 9) | `CAMetalLayer.h:118-122`                                   |
| `CALayer.toneMapMode` (`.automatic`, `.never`, `.ifSupported`)                     | 18.0                        | `CALayer.h:40-55`, `:461`                                  |
| `CALayer.preferredDynamicRange` (`.standard`, `.constrainedHigh`, `.high`)         | 26.0                        | `CALayer.h:60-90`, `:469`                                  |
| `kCGColorSpaceITUR_2100_PQ`, `kCGColorSpaceITUR_2100_HLG`                          | 14.0 (inferred)             | `TV/CoreGraphics.framework/Headers/CGColorSpace.h:154-157` |

Semantics on macOS and iOS, for reference: content is display-referred linear relative to SDR white. `opticalOutputScale` is the cd/m² that a buffer value of 1.0 maps to (for example 100). For a normalized pixel format the scale is assumed to be 10,000 (`MAC/QuartzCore.framework/Headers/CAEDRMetadata.h:28-75`).

On tvOS, a Metal layer cannot request HDR output. It can only be colour-matched into whatever mode the box is in. UNCONFIRMED: on tvOS 26, a `CAMetalLayer` with `colorspace = itur_2100_PQ`, `preferredDynamicRange = .high` and `toneMapMode = .never` might pass PQ values through while the output is already HDR10. Even then the layer goes through the compositor and colour matching, so it is not a code-value path. Do not build on it.

### 2.3 (c) Plain UIKit or SwiftUI colours: NOT adequate

- Colours are R'G'B' in sRGB, Display P3 or extended spaces. Core Animation colour-matches them into the display space (`CAMetalLayer.h:118-122` describes the same matching for Metal).
- The UI renders at 1920×1080 points and is scaled 2× for 4K. Edges are resampled.
- In HDR10 or Dolby Vision output, the box maps SDR UI into PQ at an SDR white level the system chooses. No API exposes that level.
- tvOS 26 HDR colour APIs (`UIColor` exposure and `contentHeadroom`, `UIColor.h:55-111`) are relative and tone-mapped. They are not absolute code values.
- The box does the YCbCr conversion and range scaling for UI content, and may dither.
- Result: patch values are not traceable. Existing UI-based Apple TV pattern apps are reported as not bit-perfect ([Light Illusion forum](https://lightillusion.com/forums/display-calibration-8/apple-tv-4k-yr.-2021-bit-perfect-861.html)). Use UIKit and SwiftUI only for menus and the on-screen display.

### 2.4 Recommendation

**Primary:** `AVSampleBufferDisplayLayer` through `sampleBufferRenderer`. Feed it IOSurface-backed `'x420'` narrow-range buffers with full colour and HDR attachments. Request the mode with `AVDisplayCriteria(refreshRate:formatDescription:)` built from the same buffer.

- This is the only public path Apple documents for app-generated HDR video (section 0, item 5).
- It uses the video pipeline, not UI compositing.
- The codes are already in the HDMI wire format (narrow-range Y'CbCr). With HDMI Output = YCbCr there is no R'G'B' or range conversion to add error.

**Fallback:** `AVPlayer` (or `AVPlayerViewController` with `appliesPreferredDisplayCriteriaAutomatically`) playing pre-encoded HEVC Main10 clips: BT.709 SDR, BT.2020 PQ HDR10, and Dolby Vision Profile 5 for the Dolby Vision case.

- This is the pipeline every streaming app uses, so it is the one Apple tests most.
- It is the only public Dolby Vision route.
- The clip gives the display criteria through `load(.preferredDisplayCriteria)` if the format-description initializer fails.
- Cost: the codec is lossy. UNCONFIRMED: flat fields probably decode to exact values. Generate the clips on the Mac (VideoToolbox HEVC Main10), then send them to the box or bundle them. Users report Infuse playback of HDR patterns clipping shadow detail ([Firecore 34727](https://community.firecore.com/t/hdr-shadow-detail-on-sony-a9f/34727), [Firecore 15720](https://community.firecore.com/t/calibration-hdr-masciola-is-not-working/15720)). Verify each clip on hardware.

### 2.5 HDMI output format, chroma and buffer size

- HDMI Output options: "YCbCr, RGB High, and RGB Low". "YCbCr is preferred for most TVs" ([Apple video settings](https://support.apple.com/guide/tv/change-video-settings-atvb553e7afe/tvos)). Tell users to choose YCbCr. With RGB, the box converts our Y'CbCr to R'G'B' and rounds.
- Chroma: Apple's current guide offers "4:2:0" and "4:4:4 (requires a high-speed HDMI cable)" (same page, written for newer models). On the 1st gen (HDMI 2.0a), 4K60 HDR is 4:2:2 or 4:2:0 (section 1.8). UNCONFIRMED: the exact chroma options shown on a 1st-gen box with tvOS 26. Read them in Settings.
- Flat patches are not affected by chroma subsampling, except within a few pixels of patch edges. Measure the centre.
- SDR at 4K60 in RGB or 4:4:4 is 8-bit on HDMI 2.0. Put SDR patterns on the 8-bit grid (10-bit code = 8-bit code × 4), so that truncation is exact. UNCONFIRMED: whether the box dithers.
- Buffer size: make the buffer equal to the output mode (`UIScreen.main.currentMode?.size` or `nativeBounds`). UNCONFIRMED: which of them reports 3840×2160 on the 1st gen. A 1920×1080 buffer is upscaled 2×. Flat interiors stay unchanged, edges are filtered.
- Firecore users saw banding at 2160p24/25/30 HDR, but not at 2160p50/60 or 1080p HDR ([Firecore 15543](https://community.firecore.com/t/apple-tv-4k-strange-video-quality-problem/15543)). Test 4K60 and 1080p60.
- Memory: 3840×2160 `'x420'` is 3840 × 2160 × 2 B × 1.5 ≈ 24.9 MB per buffer. A pool of 2 or 3 buffers is enough.
- TV and box setup: TV in "Just Scan" (no overscan). Apple TV Color Balance (Settings > Video and Audio > Calibration) must be on "Use Original", because a balanced setting changes the box's output ([AppleInsider](https://appleinsider.com/articles/21/04/24/how-to-color-balance-your-apple-tv-with-your-iphone)).

## 3. Dolby Vision

### 3.1 Public routes

There is no public API for Dolby Vision output from app pixels. Dolby Vision appears on HDMI only in these cases:

1. The box plays Dolby-Vision-encoded media and Match Dynamic Range is on. The 1st gen lists Profile 5 ([Apple 111929](https://support.apple.com/en-us/111929)). Profile 8.1 support on newer tvOS is community-reported ([Firecore 43452](https://community.firecore.com/t/criteria-for-dolby-vision-profile-8/43452)). UNCONFIRMED on the 1st gen.
2. The user sets Video Format = Dolby Vision with matching off. The box converts everything to Dolby Vision (section 1.7).

Other routes:

- `AVDisplayCriteria(refreshRate:videoDynamicRange: 4)`: private, so App Store rejection under 2.5.1. Kodi and KSPlayer use it. KSPlayer's maintainer says the format-description initializer "carries no DV information" ([KSPlayer #633](https://github.com/kingslay/KSPlayer/issues/633)).
- `AVDisplayCriteria(refreshRate:formatDescription:)` with a `'dvh1'` description that carries a `dvcC` atom: UNCONFIRMED. Nobody has published a working example.
- Criteria loaded from a bundled Dolby Vision Profile 5 clip with `load(.preferredDisplayCriteria)`: public. UNCONFIRMED: probably switches HDMI to Dolby Vision. Our PQ pixel buffers shown in that mode are converted by the box, so this is not faithful either.
- Producing Dolby Vision pattern clips needs an RPU. Apple's encoders do not author Profile 5 or 8.1 RPUs. That needs third-party tools (for example `dovi_tool`) and raises Dolby trademark and licensing questions.

### 3.2 Existing Apple TV pattern apps

| App or source                                                                                                                                                                              | Platform                                                                                                | HDR handling                                                                                                                                                                          | Source                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| HD Test Patterns                                                                                                                                                                           | tvOS 11+                                                                                                | "For SDR calibration only"                                                                                                                                                            | [App Store](https://apps.apple.com/ai/app/hd-test-patterns/id1225888213)                                                                                                                 |
| 4K Test Patterns                                                                                                                                                                           | tvOS 13.4+                                                                                              | No HDR mentioned                                                                                                                                                                      | [App Store](https://apps.apple.com/us/app/4k-test-patterns/id1518092883)                                                                                                                 |
| LightSpace Connect (Caplaz, with ColourSpace/LightSpace)                                                                                                                                   | Light Illusion lists "iPhone, iPad & AppleTV". The App Store listing fetched 2026-10-31 shows Mac only. | HDR needs a video generator licence. A search-engine snippet of an AVS Forum post says it gives SDR only on Apple TV (not fetched, behind a paywall). Calman no longer works with it. | [Light Illusion](https://lightillusion.com/lightspace_connect.html), [App Store](https://apps.apple.com/us/app/id1456330684)                                                             |
| Portrait Displays Patterns Mobile                                                                                                                                                          | iOS and iPadOS only, no tvOS                                                                            | HDR on iOS, works with Calman                                                                                                                                                         | [App Store](https://apps.apple.com/app/id1658658195)                                                                                                                                     |
| Pre-encoded pattern videos (Mehanik HDR10 set from AVS Forum, Diversified Video Solutions HDR10/DV discs, Netflix test patterns) played with Infuse or AVPlayer and Match Dynamic Range on | any player                                                                                              | HDR10 and DV through media, with reported shadow clipping in Infuse                                                                                                                   | [Firecore 34727](https://community.firecore.com/t/hdr-shadow-detail-on-sony-a9f/34727), [Firecore 15720](https://community.firecore.com/t/calibration-hdr-masciola-is-not-working/15720) |

No tvOS app found generates HDR10 or Dolby Vision patches live. Calibration professionals recommend dedicated generators for bit-exact work (for example PGenerator, per the [Light Illusion forum](https://lightillusion.com/forums/display-calibration-8/apple-tv-4k-yr.-2021-bit-perfect-861.html)).

### 3.3 The capability boundary to state in the product

> Nitpick shows SDR (BT.709) and HDR10 (PQ, BT.2020) patches through the Apple TV's video pipeline. When the TV setup in the guide is used, the patch code values are expected to pass through unchanged, but tvOS does not promise this, and Nitpick cannot read the HDMI signal. Nitpick switches the Apple TV to HDR10 only when Match Dynamic Range is on. Nitpick cannot produce Dolby Vision patches: the Apple TV outputs Dolby Vision only for Dolby Vision video, and in Dolby Vision mode the TV's own Dolby Vision processing changes every value. Apple TV HDR metadata (mastering display, MaxCLL/MaxFALL) may be replaced by tvOS. For Dolby Vision calibration on LG TVs, use the TV's built-in calibration patterns through its calibration interface.

## 4. Networking

### 4.1 API availability

| API                                                                      | tvOS | macOS | Source                                                                                 |
| ------------------------------------------------------------------------ | ---- | ----- | -------------------------------------------------------------------------------------- |
| `NWListener` (with `service: NWListener.Service`)                        | 12.0 | 10.14 | `TV/Network.framework/Modules/Network.swiftmodule/arm64-apple-tvos.swiftinterface:613` |
| `NWBrowser`                                                              | 13.0 | 10.15 | same `:181-182`                                                                        |
| `NWProtocolFramer`                                                       | 13.0 | 10.15 | same `:1152`                                                                           |
| `NWProtocolWebSocket` (client and listener)                              | 13.0 | 10.15 | same `:18`                                                                             |
| `NetworkListener`, `NetworkBrowser`, `NetworkConnection` (new Swift API) | 26.0 | 26.0  | same `:121-134`, `:1069`, `:1759-1760`                                                 |
| `sec_protocol_options_add_pre_shared_key`                                | 12.0 | 10.14 | `TV/Security.framework/Headers/SecProtocolOptions.h:357-373`                           |
| `sec_protocol_options_set_min_tls_protocol_version` / `_max_`            | 13.0 | 10.15 | same `:186-256`                                                                        |
| `sec_protocol_options_append_tls_ciphersuite`                            | 13.0 | 10.15 | same `:105-118`                                                                        |
| `sec_protocol_options_set_verify_block`                                  | 12.0 | 10.14 | same `:751-767`                                                                        |
| `TLS_PSK_WITH_AES_128_GCM_SHA256 = 0x00A8`                               | n/a  | n/a   | `TV/Security.framework/Headers/CipherSuite.h:197`                                      |

Keep the classic `NW*` API on both sides. The new Swift API would need macOS 26 on the Mac.

### 4.2 Info.plist keys and the local network prompt

From [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy):

- Local network privacy: iOS 14, macOS 15, visionOS 1. **tvOS: no.** watchOS: no.
- "All Bonjour operations require local network access" (register, browse, resolve).
- Needs access: outgoing TCP, UDP unicast/multicast/broadcast send, receiving multicast or broadcast. Does not need access: listening for and accepting TCP, receiving UDP unicast.
- Add `NSLocalNetworkUsageDescription` and `NSBonjourServices` (for example `_nitpick._tcp`).
- "The multicast entitlement isn't required on macOS."
- The prompt appears on the first local network operation. The system "may deny the operation immediately, before the user has responded". Use `NWConnection` or `NWBrowser` waiting states.
- Detect denial: `connection.currentPath?.unsatisfiedReason == .localNetworkDenied`, or `kDNSServiceErr_PolicyDenied` (-65570) in the `NWBrowser` waiting state. After a grant, "the system automatically retries".
- Sign with an Apple-issued identity. Ad-hoc signing makes the privacy state unreliable.
- tvOS: no prompt. Keep both keys in the tvOS `Info.plist`. They are harmless. UNCONFIRMED: whether tvOS needs `NSBonjourServices` to advertise.

### 4.3 macOS App Sandbox entitlements

| Need                                                         | Entitlement                                                                                           | Source                                                                                                                                     |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Mandatory for the Mac App Store                              | `com.apple.security.app-sandbox`                                                                      | [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox), guideline 2.4.5(i) |
| TCP or TLS to the Apple TV, wss to the LG TV, Bonjour browse | `com.apple.security.network.client`                                                                   | same                                                                                                                                       |
| Any UDP, including SSDP M-SEARCH to 239.255.255.250:1900     | `network.client` **and** `com.apple.security.network.server`. Quinn: "working with UDP requires both" | [forum 772642](https://developer.apple.com/forums/thread/772642)                                                                           |
| Colorimeter over USB                                         | `com.apple.security.device.usb`                                                                       | section 5                                                                                                                                  |

SSDP: Quinn says Network framework multicast support (`NWConnectionGroup` with `NWMulticastGroup`) is limited. Use BSD sockets where it is not enough ([forum 772642](https://developer.apple.com/forums/thread/772642)). App Transport Security (ATS) does not apply to BSD sockets or Network framework ([OWASP MASTG](https://mas.owasp.org/MASTG/knowledge/ios/MASVS-NETWORK/MASTG-KNOW-0073/)).

### 4.4 TLS with a pre-shared key

- Network framework supports TLS-PSK with TLS 1.2 only. Quinn: "we only support TLS-PSK with TLS 1.2" ([forum 768961](https://developer.apple.com/forums/thread/768961)). Set min = max = TLS 1.2.
- Apple's TicTacToe sample ([Building a custom peer-to-peer protocol](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol)) uses PSK = HMAC-SHA256(key: passcode, message: "TicTacToe"), identity "TicTacToe", and cipher suite `TLS_PSK_WITH_AES_128_GCM_SHA256` ([forum 745186](https://developer.apple.com/forums/thread/745186)).
- Apple has not answered the security question about that sample (FB13589481).

```swift
let tls = NWProtocolTLS.Options()
let sec = tls.securityProtocolOptions
sec_protocol_options_add_pre_shared_key(sec, psk as __DispatchData, identity as __DispatchData)
sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
```

Weaknesses and the smallest fix:

- The suite has no forward secrecy.
- A short pairing code can be brute-forced offline from one captured handshake.
- Smallest fix: the TV shows a 6-digit or longer code for the first connection only. Over that session, exchange a random 32-byte key. Both sides store it in the Keychain and use it as the PSK from then on.
- `TLS_ECDHE_PSK_*` suites exist in `CipherSuite.h:121-126`. UNCONFIRMED: whether Network framework negotiates them.

### 4.5 Framing

TicTacToe uses a custom `NWProtocolFramer`. Simpler: put `NWProtocolWebSocket.Options()` on top of TCP and TLS-PSK. You get message boundaries and ping without framer code, and `NWListener` accepts WebSocket on tvOS 13+.

```swift
let params = NWParameters(tls: tls, tcp: .init())
params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
```

### 4.6 tvOS lifecycle

- Design for foreground only. UNCONFIRMED: Apple documents no tvOS background mode that keeps a network listener alive.
- Start the listener when the scene becomes active. Cancel it when the scene goes to the background.
- During a pattern session, set `UIApplication.shared.isIdleTimerDisabled = true`, and reset it at the end. Apple's text: "apps ... can, by setting this property to true, disable the 'idle timer' to avert system sleep" ([isIdleTimerDisabled](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled)).
- Developers report screensaver regressions despite the flag on tvOS 11 and 14 ([forum 93742](https://developer.apple.com/forums/thread/93742), [forum 684097](https://developer.apple.com/forums/thread/684097)). One tvOS developer reports the flag stops the app being pushed out while music plays ([forum 813843](https://developer.apple.com/forums/thread/813843)).
- Also set `AVSampleBufferDisplayLayer.preventsDisplaySleepDuringVideoPlayback` (tvOS 13).

### 4.7 WebSocket to an LG TV (wss on port 3001, self-signed certificate)

LG TVs moved to self-signed certificates. Port 3001 (wss) works where port 3000 (ws) is blocked ([Homey forum](https://community.homey.app/t/lg-webos-better-integration/15007/445)).

| Option                                                                           | ATS                                                                                                                                                                                                                                                        | Certificate handling                                                                                                 | Verdict                          |
| -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| `NWConnection` + `NWProtocolWebSocket` + `sec_protocol_options_set_verify_block` | not involved                                                                                                                                                                                                                                               | Your block decides. Pin the leaf certificate, with no `SecTrustEvaluate`, so weak or old LG certificates still work. | **Recommended**                  |
| `URLSessionWebSocketTask` + `urlSession(_:didReceive:completionHandler:)`        | applies. Since macOS 14, ATS blocks IP addresses by default; add `NSAllowsLocalNetworking` ([NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)) | `.useCredential` with `URLCredential(trust:)` after the pin check                                                    | Works, but has more moving parts |

Trust on first use: the iLG remote app takes this approach. It records the TV's certificate on first connection and refuses later changes ([openrepos](https://openrepos.net/comment/45340)).

```swift
sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, done in
    let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
    let der = chain?.first.map { SecCertificateCopyData($0) as Data }
    let hash = der.map { Data(SHA256.hash(data: $0)) }
    done(hash != nil && (pinned == nil || hash == pinned))  // store hash on first success
}, .main)
```

## 5. USB HID from a sandboxed Mac app

| Fact                                                                                                                                                                                                 | Source                                                                                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `IOHIDManager` is available since macOS 10.5                                                                                                                                                         | `MAC/IOKit.framework/Headers/hid/IOHIDManager.h:109-126`                                                                                                                                                |
| `CoreHID` (`HIDDeviceManager`, `HIDDeviceClient`) is macOS 15. Apple DTS: "The modern API for this is actually 'CoreHID,' which I what I'd recommend building on."                                   | `MAC/CoreHID.framework/.../arm64e-apple-macos.swiftinterface:175,3517`, [forum 804793](https://developer.apple.com/forums/thread/804793)                                                                |
| `com.apple.security.device.usb`: "allow your sandboxed app to interact with USB devices through USB device access APIs", macOS 10.7                                                                  | [device.usb](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb)                                                                                      |
| Input Monitoring is required "for anything that the system itself 'directly' understands (keyboard, mice, etc)". The right device type may avoid it.                                                 | [forum 804793](https://developer.apple.com/forums/thread/804793)                                                                                                                                        |
| A sandboxed app with `device.usb` got "TCC deny IOHIDDeviceOpen" on a keyboard                                                                                                                       | [forum 724608](https://developer.apple.com/forums/thread/724608)                                                                                                                                        |
| Hardened runtime exceptions include no USB or HID entitlement. Hardened runtime is needed for notarization. "you aren't required to notarize software that you distribute through the Mac App Store" | [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime), [Notarizing](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) |

- UNCONFIRMED and the biggest product risk: whether a sandboxed app with `device.usb` can open an i1d3-family colorimeter (Calibrite Display Plus HL) and exchange HID reports with it. No Apple document says that `device.usb` covers HID. No Mac App Store precedent was found.
- A 2011 WWDC slide said "SandBox access not allowed for HID devices" ([WWDC 2011 session 207](https://docs.huihoo.com/apple/wwdc/2011/session_207__user_level_device_access.pdf)). It predates the current entitlement model.
- First spike: build a minimal sandboxed app with `device.usb`. Use CoreHID to enumerate the meter, open it, send the unlock and measure reports, and read input reports. If CoreHID fails, try IOHIDManager. If both fail, open a DTS incident. The last resort (Developer ID outside the Mac App Store) breaks universal purchase.
- Hardened runtime: `ENABLE_HARDENED_RUNTIME = YES` is harmless and needs no extra entitlement for HID.
- App Review: the guidelines found contain no USB rule. The real risks are 2.1 (the reviewer has no meter) and 2.5.1 (CoreHID and IOKit HID are public, so that one is fine).

## 6. Project structure for universal purchase

### 6.1 Apple rules

- "a macOS, tvOS, visionOS app ... uses the same Apple ID (an app identifier), SKU, and bundle ID" ([Universal purchase](https://developer.apple.com/support/universal-purchase/)).
- "you must upload the builds for macOS, tvOS, and visionOS from a separate Xcode target. In the Xcode project, set the bundle IDs to match ... may each have different version numbers and build strings" (same page).
- A record with macOS + tvOS and no iOS: the New App dialog lets you "select one or more platforms" from iOS, macOS, tvOS and visionOS, and "All platforms will share the same bundle ID" ([Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)). Inference: iOS is not required. Not stated outright.
- The purchase becomes universal once review approves two platform versions. After that, "your app stays as universal purchase" and you cannot remove a single platform. Separate records cannot be merged ([Universal purchase](https://developer.apple.com/support/universal-purchase/)).

### 6.2 What must differ per target

| Item                 | macOS target                                                                                                                                  | tvOS target                                                                                                                                                                                                                                                                                                                                                                                                           |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SDK / platform       | macosx                                                                                                                                        | appletvos, `TARGETED_DEVICE_FAMILY = 3`                                                                                                                                                                                                                                                                                                                                                                               |
| Info.plist           | own                                                                                                                                           | own                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Entitlements         | sandbox, `network.client` (+ `network.server` if SSDP), `device.usb`, user-selected files                                                     | none needed for this design                                                                                                                                                                                                                                                                                                                                                                                           |
| Provisioning profile | Mac App Store profile                                                                                                                         | tvOS profile (same App ID)                                                                                                                                                                                                                                                                                                                                                                                            |
| App icon             | 1024×1024, PNG asset catalog or Icon Composer file ([HIG App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)) | Layered image stack, 2 to 5 layers, 800×480 px layout. "For tvOS and visionOS app icons, you add your icon layers directly to an image stack in Xcode". Icon Composer does not support tvOS (same page).                                                                                                                                                                                                              |
| Extra tvOS assets    | n/a                                                                                                                                           | Brand assets: App Icon (small, 400×240 pt), App Icon – App Store (1280×768), Top Shelf Image (1920×720), Top Shelf Image Wide (2320×720 pt; HIG: [Top Shelf](https://developer.apple.com/design/human-interface-guidelines/top-shelf)). Missing wide image: upload errors ITMS-90471 and ITMS-90513 ([forum 92000](https://developer.apple.com/forums/thread/92000)). Images must be opaque (ITMS-90497, ITMS-90523). |
| Versions             | may differ                                                                                                                                    | may differ                                                                                                                                                                                                                                                                                                                                                                                                            |

### 6.3 XcodeGen and Swift packages

- XcodeGen `platform:` accepts `iOS`, `tvOS`, `macOS`, `watchOS`, `visionOS` and `auto`. Local packages use `packages: Name: path:`, and targets use `dependencies: - package: Name, products: [...]`. Per-platform `options.deploymentTarget`, and `info` / `entitlements` blocks can generate the plists ([ProjectSpec.md](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)).
- The latest release is 2.46.0. Its release notes mention Xcode 16 (object version 77) and nothing about Xcode 26 or 27 ([releases](https://github.com/yonaskolb/XcodeGen/releases)). UNCONFIRMED: clean generation for Xcode 27. Run `xcodegen generate` and open the project once.
- `.tvOS(.v26)` and `.macOS(.v26)` in `Package.swift` need `// swift-tools-version: 6.2` or later. `.v27` needs 6.4. Path: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface:570-603`.

### 6.4 Framework availability

| Framework                   | tvOS | macOS | Source                                                               |
| --------------------------- | ---- | ----- | -------------------------------------------------------------------- |
| SwiftUI                     | 13   | 10.15 | SDK                                                                  |
| Swift Charts (`Chart`)      | 16.0 | 13.0  | `TV/Charts.framework/.../arm64-apple-tvos.swiftinterface:608`        |
| Observation (`@Observable`) | 17.0 | 14.0  | `TVSWIFT/Observation.swiftmodule/arm64-apple-tvos.swiftinterface:24` |
| CoreHID                     | n/a  | 15.0  | section 5                                                            |

### 6.5 Deployment targets

- **tvOS: keep 18.0 (the current `project.yml` value) or use 26.0. Never higher than 26.x.**
  - Every API the renderer needs is tvOS 17.4 or earlier: criteria from a format description is 17.0, `sampleBufferRenderer` 17.0, `copyDisplayedPixelBuffer` 17.4.
  - 26.0 only adds nice-to-haves: `recommendedPixelBufferAttributes`, `CALayer.preferredDynamicRange`, and `NetworkListener`. Gate them with `#available` if you stay at 18.
  - Every Apple TV that runs tvOS 18 can run tvOS 26, so 26.0 drops no updated user.
- **macOS: 15.0.** This version adds CoreHID, and the local network prompt starts here. `@Observable`, Charts and `NWBrowser` are older.
- Swift 6 notes: `AVDisplayCriteria` is `Sendable`. `AVSampleBufferVideoRenderer` is `NS_SWIFT_NONSENDABLE`. With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, enqueue from the main actor. That is fine for static patterns.

## 7. App Store blockers and the smallest fix for each

| Blocker                                                 | Guideline                                                                                             | Smallest viable solution                                                                                                                                             |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The tvOS app needs the Mac app to work                  | 4.2.3(i): "Your app should work on its own without requiring installation of another app to function" | Standalone mode on tvOS: a Siri Remote menu of built-in patterns (SDR and HDR10 windows, grey ramp, PLUGE). It also meets 2.4.3 (usable with the Siri Remote alone). |
| The reviewer has no colorimeter or LG TV                | 2.1 and "Before You Submit": provide "any other hardware or resources that might be needed"           | Simulated-meter demo mode on the Mac (the project already plans simulated devices), plus review notes and a demo video link                                          |
| Mac sandbox                                             | 2.4.5(i)                                                                                              | Entitlements from section 4.3                                                                                                                                        |
| No license keys or own copy protection                  | 2.4.5(vi)                                                                                             | Paid up front or IAP. No key screen.                                                                                                                                 |
| Private API (`videoDynamicRange` initializer)           | 2.5.1                                                                                                 | Do not use it. Use `init(refreshRate:formatDescription:)`.                                                                                                           |
| Trademarks: "Dolby Vision", "LG", "Calman", "Calibrite" | 5.2.1, 4.1(c), 2.3.7                                                                                  | Use descriptive text only ("works with LG webOS TVs"). No third-party logos. Keep these names out of the app name and keywords.                                      |
| Account requirement                                     | 5.1.1(v)                                                                                              | None. No login.                                                                                                                                                      |
| macOS local network prompt                              | TN3179                                                                                                | Clear `NSLocalNetworkUsageDescription`, plus handling of the denied state in the UI                                                                                  |
| Notarization or hardened runtime                        | not needed for the Mac App Store                                                                      | Keep hardened runtime on. It is harmless.                                                                                                                            |
| Universal purchase cannot be undone                     | Universal purchase page                                                                               | Decide before the second platform is approved                                                                                                                        |
| Feature unlock tied to hardware                         | 3.1.4 allows unlocking with hardware                                                                  | Not needed if the app is paid up front                                                                                                                               |

## 8. Facts the implementer can rely on

1. Apple TV 4K (1st gen) cannot run tvOS 27. Its ceiling is tvOS 26.x ([MacRumors](https://www.macrumors.com/2026/09/15/tvos-27-compatible-apple-tv-models/)).
2. `AVDisplayCriteria` has exactly one initializer: `init(refreshRate: Float, formatDescription: CMFormatDescription)`, tvOS 17.0 (`TV/AVFoundation.framework/Headers/AVDisplayCriteria.h`).
3. `UIWindow.avDisplayManager` (tvOS 11.2), `preferredDisplayCriteria`, KVO-observable `isDisplayModeSwitchInProgress` (11.2), `isDisplayCriteriaMatchingEnabled` (11.3) and three notifications (11.3) (`TV/AVKit.framework/Headers/AVDisplayManager.h`, `UIWindow.h:25-27`).
4. `AVPlayer.HDRMode` values are `hlg = 0x1`, `hdr10 = 0x2`, `dolbyVision = 0x4`, deprecated in tvOS 26. Use `eligibleForHDRPlayback` (`TV/AVFoundation.framework/Headers/AVPlayer.h:663-694`).
5. `AVSampleBufferDisplayLayer` (tvOS 10.2), `sampleBufferRenderer` (17.0), `copyDisplayedPixelBuffer` (17.4), `recommendedPixelBufferAttributes` (26.0) (`AVSampleBufferDisplayLayer.h:36,246`, `AVSampleBufferVideoRenderer.h:213-256`).
6. `'x420'` stores each 10-bit sample in the most significant bits of 16 bits. Video range is luma 64 to 940 and chroma 64 to 960 (`TV/CoreVideo.framework/Headers/CVPixelBuffer.h:111`).
7. The mastering display attachment is 24 bytes, big-endian, in the HEVC D.2.28 layout. Content light level is 4 bytes, big-endian (`TV/CoreVideo.framework/Headers/CVImageBuffer.h:225-229`; `TV/CoreMedia.framework/Headers/CMFormatDescription.h:897-899`).
8. Colour primaries, transfer function (including `SMPTE_ST_2084_PQ` and `ITU_R_2100_HLG`) and Y'CbCr matrix constants are available on tvOS (`CVImageBuffer.h:73-101`).
9. A sample buffer's format description must match the image buffer's attachments for the common keys (`TV/CoreMedia.framework/Headers/CMSampleBuffer.h:656-684`).
10. `kCMSampleAttachmentKey_DisplayImmediately` is tvOS 9. The Swift overlay `sampleAttachments[0][.displayImmediately]` is tvOS 13 (`CMSampleBuffer.h:1518`, CoreMedia swiftinterface `:2202`).
11. `CAMetalLayer.wantsExtendedDynamicRangeContent`, `CAMetalLayer.EDRMetadata` and `CAEDRMetadata` are unavailable on tvOS (`TV/QuartzCore.framework/Headers/CAMetalLayer.h:128-138`, `CAEDRMetadata.h:15`).
12. `UIScreen.availableModes` and `preferredMode` are unavailable on tvOS. The app cannot choose an HDMI mode directly (`TV/UIKit.framework/Headers/UIScreen.h:62-63`).
13. TLS-PSK functions and `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8) exist on tvOS 12/13 and macOS 10.14/10.15 (`TV/Security.framework/Headers/SecProtocolOptions.h:357-439`, `CipherSuite.h:197`). Network framework does PSK only with TLS 1.2 ([forum 768961](https://developer.apple.com/forums/thread/768961)).
14. `NWListener` (tvOS 12), `NWBrowser`, `NWProtocolFramer` and `NWProtocolWebSocket` (tvOS 13) (`TV/Network.framework/Modules/Network.swiftmodule/arm64-apple-tvos.swiftinterface`).
15. Local network privacy exists on macOS 15+ and not on tvOS. The multicast entitlement is not needed on macOS ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
16. A sandboxed Mac app needs both `network.client` and `network.server` for UDP ([forum 772642](https://developer.apple.com/forums/thread/772642)).
17. Universal purchase needs the same bundle ID, separate Xcode targets and one App Store Connect record ([Universal purchase](https://developer.apple.com/support/universal-purchase/)).
18. tvOS icons are image stacks, not Icon Composer files ([HIG App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)).
19. `.tvOS(.v26)` in a package manifest needs swift-tools-version 6.2 (PackageDescription swiftinterface `:600-601`).

## 9. UNCONFIRMED: verify on hardware

Test bench: Apple TV 4K (1st gen) on tvOS 26.x, an HDMI capture card that records 10-bit Y'CbCr (for example 1080p60 4:2:2), an HDFury (or similar) InfoFrame reader, the LG TV and the colorimeter.

| #   | Question                                                                                                                                               | How to test                                                                                                                                                   |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Does `AVDisplayCriteria(refreshRate:formatDescription:)` built from a PQ `'x420'` buffer switch the 1st gen to HDR10, and a BT.709 buffer back to SDR? | Read the InfoFrame (EOTF field). Log `isDisplayModeSwitchInProgress` timing.                                                                                  |
| 2   | Are `'x420'` codes bit-exact on HDMI in SDR and HDR10, at 1080p60 and 2160p60, with HDMI Output = YCbCr?                                               | Capture a frame of patches: codes 4, 64, 65, 66, 512, 940, 1019, and coloured Cb/Cr extremes. Diff against the sent values. Repeat with 8-bit-grid SDR codes. |
| 3   | Does the box dither (temporal or spatial)?                                                                                                             | Capture several frames of a flat patch and check variance.                                                                                                    |
| 4   | Do the mastering display and MaxCLL/MaxFALL attachments reach the HDR InfoFrame, or does tvOS 26 substitute values?                                    | HDFury readout with P3-D65 and BT.2020 mastering primaries                                                                                                    |
| 5   | Is the last enqueued frame held indefinitely with no `controlTimebase`, and does `copyDisplayedPixelBuffer()` return our buffer?                       | Enqueue once and wait 10 minutes with the idle timer disabled                                                                                                 |
| 6   | Real mode-switch durations, and does the switch end notification arrive?                                                                               | Timestamps from KVO to the first stable capture frame                                                                                                         |
| 7   | Chroma options shown on a 1st gen with tvOS 26, and the output bit depth per mode                                                                      | Settings plus InfoFrame (colour space, depth)                                                                                                                 |
| 8   | `UIScreen.currentEDRHeadroom`, `nativeBounds` and `currentMode.size` values in SDR, HDR10 and DV output                                                | Log them                                                                                                                                                      |
| 9   | Does a bundled Dolby Vision Profile 5 clip's criteria switch HDMI to DV, and what happens to PQ buffers in that mode?                                  | InfoFrame and TV badge                                                                                                                                        |
| 10  | Is `isDisplayCriteriaMatchingEnabled` true when only Match Frame Rate is on?                                                                           | Toggle the settings                                                                                                                                           |
| 11  | Can a sandboxed app with `device.usb` open the i1d3-family meter through CoreHID or IOHIDManager without Input Monitoring?                             | First spike, before anything else in MeterKit                                                                                                                 |
| 12  | Does a flat-field HEVC Main10 clip decode to exact codes (fallback path)?                                                                              | Capture and diff                                                                                                                                              |
| 13  | Does `xcodegen generate` (2.46.0) produce a clean Xcode 27 project for a tvOS target with a local package?                                             | Generate, build and archive both targets                                                                                                                      |
| 14  | Does tvOS need `NSBonjourServices` to advertise, and do the `TLS_ECDHE_PSK_*` suites negotiate?                                                        | Remove the key or append the suite, then connect                                                                                                              |

## 10. Recommended renderer design (15 lines)

1. `PatternView` (`UIViewRepresentable`) hosts a `UIView` whose `layerClass` is `AVSampleBufferDisplayLayer`, full screen, `videoGravity = .resize`.
2. `PatternRenderer` (main actor) owns a `CVPixelBufferPool`: IOSurface-backed `'x420'`, size = `UIScreen.main.currentMode.size`.
3. Input is a `PatternSpec` from the Mac: mode (SDR709 or HDR10), background Y'CbCr, window rectangle, window Y'CbCr, optional MaxCLL/MaxFALL.
4. `fill()` writes `code << 6` into plane 0 (Y') and plane 1 (Cb, Cr), using bytes-per-row per plane. No floating point on the device.
5. The Mac does the R'G'B'→Y'CbCr maths (ColorScience) and sends integer codes, so the box never rounds.
6. `attach()` sets primaries, transfer function, matrix and chroma location, and for HDR10 the 24-byte MDCV and 4-byte CLLI `Data`. This happens before the format description is made.
7. One cached `CMVideoFormatDescription` per mode. It is rebuilt only when the attachments change.
8. On a mode change: set `preferredDisplayCriteria = AVDisplayCriteria(refreshRate: screen.maximumFramesPerSecond, formatDescription:)`.
9. Wait for the KVO `isDisplayModeSwitchInProgress` false and the end notification, then a guard delay (2 s, set by the Mac).
10. If `!isDisplayCriteriaMatchingEnabled`, send `.matchingDisabled` to the Mac. The Mac shows the setup hint and proceeds only after user confirmation.
11. Enqueue: `CMSampleBuffer(imageBuffer:formatDescription:sampleTiming:)` with `.displayImmediately`, then `sampleBufferRenderer.enqueue`.
12. Poll `copyDisplayedPixelBuffer() === pb` (at most 500 ms). Then reply `.displayed(patternID, uptime)`. The Mac adds the TV settle time.
13. On `renderer.status == .failed` or `requiresFlushToResumeDecoding`: flush, re-enqueue and report the error.
14. While a session is active: `isIdleTimerDisabled = true` and `preventsDisplaySleepDuringVideoPlayback = true`. Both are reset when the session ends or the scene goes to the background.
15. Fallback switch `useClipPlayback`: an `AVPlayer` plays a pre-encoded HEVC clip, and its criteria come from `load(.preferredDisplayCriteria)`. This is the only Dolby Vision route.

## 11. Sources

Apple documentation and support

- [AVDisplayCriteria](https://developer.apple.com/documentation/avfoundation/avdisplaycriteria)
- [AVDisplayManager](https://developer.apple.com/documentation/avkit/avdisplaymanager)
- [Tech Talk 503: Delivering an exceptional HDR experience on Apple TV](https://developer.apple.com/videos/play/tech-talks/503/)
- [Apple 102277: Match Dynamic Range / Match Frame Rate](https://support.apple.com/en-us/102277)
- [Apple TV User Guide: Change video settings](https://support.apple.com/guide/tv/change-video-settings-atvb553e7afe/tvos)
- [Apple 102339: 4K, HDR, HDR10+, Dolby Vision on Apple TV 4K](https://support.apple.com/en-us/102339)
- [Apple 111929: Apple TV 4K (1st generation) tech specs](https://support.apple.com/en-us/111929)
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Building a custom peer-to-peer protocol (TicTacToe)](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol)
- [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
- [isIdleTimerDisabled](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled)
- [com.apple.security.device.usb](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [CoreHID](https://developer.apple.com/documentation/corehid)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Universal purchase](https://developer.apple.com/support/universal-purchase/)
- [App Store Connect: Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
- [HIG: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [HIG: Top Shelf](https://developer.apple.com/design/human-interface-guidelines/top-shelf)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

Apple Developer Forums

- [830876: no API for current display mode](https://developer.apple.com/forums/thread/830876)
- [772642: Broadcasts and Multicasts, Hints and Tips (Quinn)](https://developer.apple.com/forums/thread/772642)
- [768961: TLS-PSK is TLS 1.2 only (Quinn)](https://developer.apple.com/forums/thread/768961)
- [745186: TicTacToe PSK code and security question](https://developer.apple.com/forums/thread/745186)
- [804793: CoreHID and Input Monitoring](https://developer.apple.com/forums/thread/804793)
- [724608: TCC deny IOHIDDeviceOpen in the sandbox](https://developer.apple.com/forums/thread/724608)
- [93742](https://developer.apple.com/forums/thread/93742), [684097](https://developer.apple.com/forums/thread/684097), [813843](https://developer.apple.com/forums/thread/813843): idle timer on tvOS
- [92000: ITMS-90471 Top Shelf images](https://developer.apple.com/forums/thread/92000)

Specifications

- [ITU-R BT.2100](https://www.itu.int/rec/R-REC-BT.2100)
- [ITU-R BT.709](https://www.itu.int/rec/R-REC-BT.709)
- [x265 CLI: --master-display, --max-cll](https://x265.readthedocs.io/en/master/cli.html)
- [Microsoft: 10-bit and 16-bit YUV formats (P010)](https://learn.microsoft.com/en-us/windows/win32/medfound/10-bit-and-16-bit-yuv-video-formats)

Open-source code

- [Kodi TVOSDisplayManager.mm](https://github.com/xbmc/xbmc/blob/master/xbmc/platform/darwin/tvos/TVOSDisplayManager.mm)
- [KSPlayer issue 633](https://github.com/kingslay/KSPlayer/issues/633)
- [MPVKit PR 9: HDR10 static metadata on PQ frames](https://github.com/Drvolks/MPVKit/pull/9)
- [XcodeGen ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), [XcodeGen releases](https://github.com/yonaskolb/XcodeGen/releases)

Community reports (anecdotal, treat as hypotheses)

- [Firecore 16044: HDR metadata replaced by standard values](https://community.firecore.com/t/hdr-metadata-not-correct-replaced-by-standard-values/16044)
- [Apple Community 254507878: ATV4K HDR metadata MaxCLL/FALL](https://discussions.apple.com/thread/254507878)
- [Apple Community 254404318: Match Dynamic Range off uses Video Format](https://discussions.apple.com/thread/254404318)
- [Firecore 34769: Dolby Vision format enabled, HDR playback](https://community.firecore.com/t/4k-dolby-vision-format-enabled-what-happens-to-hdr-playback/34769)
- [Firecore 51228: bit depth and RGB tunneling](https://community.firecore.com/t/apple-tv-not-outputting-10bit-colour-depth/51228)
- [Firecore 60911: 4:2:2 on Apple TV](https://community.firecore.com/t/apple-tv-infuse-can-it-play-42-properly/60911)
- [Firecore 15543: HDR banding at 2160p24/30](https://community.firecore.com/t/apple-tv-4k-strange-video-quality-problem/15543)
- [Firecore 43452: Dolby Vision Profile 8](https://community.firecore.com/t/criteria-for-dolby-vision-profile-8/43452)
- [Firecore 34727](https://community.firecore.com/t/hdr-shadow-detail-on-sony-a9f/34727), [Firecore 15720](https://community.firecore.com/t/calibration-hdr-masciola-is-not-working/15720): HDR pattern playback issues
- [Light Illusion forum: Apple TV bit-perfect](https://lightillusion.com/forums/display-calibration-8/apple-tv-4k-yr.-2021-bit-perfect-861.html)
- [LightSpace Connect](https://lightillusion.com/lightspace_connect.html)
- [MacRumors: tvOS 27 compatible models](https://www.macrumors.com/2026/09/15/tvos-27-compatible-apple-tv-models/)
- [9to5Mac: Apple TV QMS](https://9to5mac.com/2022/11/02/apple-tv-qms/)
- [AppleInsider: Color Balance](https://appleinsider.com/articles/21/04/24/how-to-color-balance-your-apple-tv-with-your-iphone)
- [Homey forum: LG wss port 3001](https://community.homey.app/t/lg-webos-better-integration/15007/445)
- [openrepos: iLG remote certificate pinning](https://openrepos.net/comment/45340)
- [OWASP MASTG-KNOW-0073: ATS scope](https://mas.owasp.org/MASTG/knowledge/ios/MASVS-NETWORK/MASTG-KNOW-0073/)
- [WWDC 2011 session 207 slides](https://docs.huihoo.com/apple/wwdc/2011/session_207__user_level_device_access.pdf)

App Store listings

- [HD Test Patterns](https://apps.apple.com/ai/app/hd-test-patterns/id1225888213)
- [4K Test Patterns](https://apps.apple.com/us/app/4k-test-patterns/id1518092883)
- [LightSpace Connect](https://apps.apple.com/us/app/id1456330684)
- [Patterns Mobile](https://apps.apple.com/app/id1658658195)
