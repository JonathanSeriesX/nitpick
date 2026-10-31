# Nitpick

TV calibration for an LG OLED driven from a Mac, with an Apple TV as the pattern generator. One App Store product
(universal purchase): a native SwiftUI macOS app that controls the workflow and reads the colorimeter, and a tvOS app
that renders test patterns on request. No Calman, ColourSpace or ArgyllCMS dependency.

| Target      | Platform   | Bundle id                      | Role                                                   |
| ----------- | ---------- | ------------------------------ | ------------------------------------------------------ |
| `Nitpick`   | macOS 15+  | `com.jonathanseriesx.nitpick`  | Calibration controller, meter driver, LG control, charts |
| `NitpickTV` | tvOS 18+   | `com.jonathanseriesx.nitpick`  | Network-controlled pattern generator + standalone menu |

Hardware targeted: LG B4 OLED (webOS 24/25), Calibrite Display Plus HL (USB), Apple TV 4K 1st generation.

## Build

```bash
xcodegen generate            # regenerate Nitpick.xcodeproj from project.yml after adding files
open Nitpick.xcodeproj       # set DEVELOPMENT_TEAM in project.yml or Signing & Capabilities
```

```bash
cd Packages/NitpickKit && swift test
```

Command-line builds used during development:

```bash
xcodebuild -project Nitpick.xcodeproj -scheme Nitpick -destination 'platform=macOS' build
```

```bash
xcodebuild -project Nitpick.xcodeproj -scheme NitpickTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' build
```

### Headless checks (Debug builds)

```bash
Nitpick.app/Contents/MacOS/Nitpick -demoRun movieSDR     # gameSDR | movieHDR10 | gameHDR10 | dolbyVision; exit 0 on pass
```

`-renderScreenshots <dir>` renders the main screens with demo data to PNG files; the tvOS app accepts
`-debugScreen menu` (or a pattern name) to open a screen directly in the simulator.

## Layout

- `Apps/NitpickMac` – macOS app (SwiftUI, Swift Charts, `@Observable`).
- `Apps/NitpickTV` – tvOS app: `AVSampleBufferDisplayLayer` renderer fed 10-bit Y'CbCr frames, TLS-PSK server,
  pairing screen, Siri-Remote pattern menu.
- `Packages/NitpickKit` – one package, five modules:
  - `ColorScience` – XYZ/xyY/Lab/ICtCp, ΔE2000/ΔE ITP/Δuv, BT.1886/PQ/HLG, primaries + Bradford, Y'CbCr, LUT types,
    CGATS (.ccss/.ccmx) parsing, spectral meter corrections.
  - `PatternLink` – pattern spec, wire protocol, length-prefixed JSON framer, TLS-PSK pairing (PIN → token), Bonjour,
    client/server actors, 10-bit frame builder with HDR10 static metadata.
  - `LGControl` – webOS SSAP WebSocket client, pairing with webOS 26 gating, SSDP discovery, Wake-on-LAN, picture
    settings via the settings-service bridge with read-back verification, `externalpq` calibration API (1D/3D LUT,
    gamut matrix, tone map, Dolby Vision config, readback) with payload validation, fake TV server with fixtures.
  - `Calibration` – device protocols, simulated OLED panel/meter/TV/pattern source, noise-aware white-balance
    optimizer, 1D and 3D LUT builders, HDR tone analysis, Dolby Vision config builder, mode-specific workflows
    (Movie SDR, Game SDR, Movie HDR10, Game HDR10, Dolby Vision), sessions, restore points, export.
  - `MeterKit` – clean-room i1d3 (Display Plus HL) HID driver over CoreHID, simulated device, EEPROM decoding,
    CCSS/CCMX corrections.
- `docs/research` – protocol and platform research the implementation was built from.
- `docs/COMMISSIONING.md` – the hardware checklist.

## Status

| Area                                        | Implemented | Verified (simulation/tests) | Needs hardware |
| ------------------------------------------- | :---------: | :-------------------------: | :------------: |
| Colour science, metrics, LUT maths          |      ✓      |              ✓              |                |
| Mac ↔ Apple TV pairing, patterns, acks      |      ✓      |     ✓ loopback + simulator  | real Apple TV  |
| 10-bit SDR/HDR10 frames with metadata       |      ✓      |      ✓ byte-level tests     | HDMI codes, InfoFrame |
| HDR10 output mode request (AVDisplayCriteria)|     ✓      |         accepted only       | mode switch    |
| Dolby Vision output                         | not possible from an app; user sets Apple TV Format to DV | – | conversion fidelity |
| LG discovery, pairing, settings read/write  |      ✓      |          ✓ fake TV          | B4 firmware    |
| LG 1D/3D LUT, matrix, tone map, DV config   |      ✓      |  ✓ byte-exact vs fixtures   | B4 acceptance, webOS ≤ 25 only |
| Meter driver (unlock, EEPROM, measure)      |      ✓      |     ✓ against fake device   | HL key, sandbox, scale |
| Workflows incl. cancel/timeout/restore      |      ✓      |     ✓ deterministic e2e     | all            |

Nothing here has calibrated a real TV yet; see `docs/COMMISSIONING.md`.

## Licences and provenance

- No third-party code. Protocol knowledge for LG comes from MIT/Apache projects (bscpylgtv, aiopylgtv, lgtv2,
  aiowebostv); the pairing manifest carries its notice. The meter driver was written from a protocol specification
  only (clean room); no GPL driver source was read by its implementer.
- CIE 1931 colour-matching data from CVRL.
