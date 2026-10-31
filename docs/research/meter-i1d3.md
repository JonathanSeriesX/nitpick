# Calibrite Display Plus HL (X-Rite i1d3 family): driver research and clean-room protocol spec

Status: research spec, 2026-10-31. Scope: the Calibrite Display Plus HL and Display Pro HL, and the i1d3 family they belong to (i1Display Pro, i1Display Pro Plus, ColorMunki Display, Calibrite ColorChecker Display / Pro / Plus), connected over USB to a Mac that runs a sandboxed App Store app (Nitpick: Swift 6, macOS 15.0 deployment target per `project.yml`).

How to read this document:

- Source tags such as [A2] point to the source list at the end. [A2] is the ArgyllCMS V3.5.0 source archive; a path after it (for example [A2 `spectro/i1d3.c`]) names the file inside the archive.
- "UNCONFIRMED" means that no primary source or raw data confirms the statement. Verify it on hardware before you depend on it.
- "Recommendation" means an engineering choice by the spec author, not a fact about the device.
- The spec author read GPL source code to write this document. The implementer must not. See section 1.6.

## 0. Summary

| Topic            | Result                                                                                                                                                                       |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Legal path       | Clean-room Swift HID driver, written only from this spec. No ArgyllCMS code, binaries or data in the app.                                                                    |
| USB identity     | VID `0x0765`, PID `0x5020` for every i1d3 variant that ArgyllCMS knows. HL uses the same PID by inference (UNCONFIRMED).                                                     |
| Transport        | USB HID. 64-byte output report (command) and 64-byte input report (reply). No report IDs.                                                                                    |
| Access gate      | The device starts "locked". A challenge/response with a per-OEM 64-bit key unlocks it. HL is reported to use the existing retail or generic-OEM key (UNCONFIRMED which one). |
| Calibration data | Per-unit RGB sensor spectral sensitivities (3 × 351 float32, 380–730 nm, 1 nm) in an 8 KB external EEPROM. The host computes the 3×3 sensor-to-XYZ matrix.                   |
| Corrections      | CCSS (display spectra) re-derive the matrix with the same math. CCMX is a 3×3 post-multiply. Do not embed third-party correction files.                                      |
| Sandbox          | `com.apple.security.device.usb` opens `IOHIDLibUserClient` in the App Sandbox (Apple DTS statement, and the local sandbox profile). No App Store precedent found.            |
| Main legal risk  | Unlocking OEM-locked meters without an X-Rite licence (DMCA §1201 and X-Rite licensing position). Needs counsel review before release.                                       |

## 1. Driver landscape and licences

### 1.1 ArgyllCMS

- The latest stable release is V3.5.0 of 4 February 2026 [A1] [A2 `log.txt`].
- The i1d3 driver is `spectro/i1d3.c` and `spectro/i1d3.h`. Their headers say "GNU GENERAL PUBLIC LICENSE Version 2 or later" [A2]. The code that the driver needs is also GPL v2+: `spectro/hidio.c`, `spectro/inst.c`, `xicc/xspect.c` (spectral math and CIE tables), `numlib/numsup.c` [A2].
- `ReadMe.txt` says the distribution as a whole "is licensed under the Affero GNU Version 3 license", and the top-level `License.txt` is AGPL v3 [A2]. The `ref/` data directory (which holds `CRT.ccss` and `oled.cmf`) also carries an AGPL v3 `License.txt` [A2 `ref/License.txt`].
- Exceptions: `cgats/` (the CGATS file parser) and `icc/` (icclib) are MIT-licensed [A2 `cgats/cgats.c`, `cgats/License4.txt`]. You do not need them; a CGATS reader is small (section 5.3).

HL support status:

- No ArgyllCMS version adds an entry for "Display Pro HL" or "Display Plus HL". The V3.5.0 source, change log and documentation contain no "HL" model string. In the source code, the only Calibrite mention is a comment on VID `0x0765`: "X-Rite, Calibrite" [A2 `spectro/insttypes.c`]. The documentation lists "Calibrite ColorChecker Display/Pro/Plus" and "Other branded i1d3's are also reported to work" [A6].
- The V3.5.0 sub-type list is: i1 DisplayPro, ColorMunki Display, i1 DisplayPro Plus / generic OEM, NEC SpectraSensor Pro, Quato Silver Haze 3, HP DreamColor, Wacom DC, Toshiba TPA-1, Barco, PhotoCrysta, ViewSonic CS-XRi1 [A2 `spectro/i1d3.h`].
- The DisplayCAL forum administrator says the Display Pro HL "is an i1d3 and it should have the same unlock code as an i1display pro or i1displaypro OEM" (October 2023) [D1], and that the Display Plus HL uses "i1Display Pro retail or OEM unlock codes" and is supported (March 2025) [D2]. ArgyllCMS tries every key in its table regardless of product name (section 3.6), so a new model with an existing key works without a code change.

Relevant i1d3 history in the change log [A2 `log.txt`]:

| Version | Date       | Change                                                                                                                                |
| ------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| 1.8.3   | 2015-10-26 | Workaround for Rev. B status code `0x83` on very low light. Maximum sensor frequency check.                                           |
| 2.2.1   | 2021-09-17 | Toshiba TPA-1 key added.                                                                                                              |
| 2.3.0   | 2021-12-24 | "Removed native i1d3 C6 instrument support as a favor to X-Rite." Added `I1D3_ESCAPE` (user-supplied keys).                           |
| 3.0.0   | 2023-09-15 | Robust handling of the Rev. B `0x83` error, which "should fix any issues measuring low level Red only patch values on OLED displays". |
| 3.1.2   | 2024-02-29 | Rev. B AIO adaptive integration time tweaked.                                                                                         |
| 3.5.0   | 2026-02-04 | Frequency mode returns exactly zero on perfect black.                                                                                 |

### 1.2 Why ArgyllCMS cannot be linked into a sandboxed App Store app

1. GPL v2+ copyleft: an app that links `i1d3.c` and its dependencies is a derivative work. The whole app must then ship under the GPL with source.
2. App Store terms: the FSF's position (GNU Go 2010, restated for VLC in November 2010) is that App Store terms of service add usage restrictions that GPLv2 section 6 forbids [L1] [L2]. The same applies to the AGPL v3 parts and the AGPL `ref/` data.
3. Bundling Argyll's `spotread` as a separate helper executable ("aggregation") does not help. It still distributes GPL binaries through the App Store under the same terms. The App Sandbox also requires every helper to be signed and sandboxed, which is possible but does not fix the licence problem.
4. Conclusion: no Argyll source, binaries, translated code or `ref/` data in the app. Get the CIE colour-matching functions from the CIE (section 4.4), not from `xspect.c`.

### 1.3 Other implementations (none is permissively licensed)

Found by a GitHub code search for the retail key constant `e9622e9f` and by web search.

| Project                                        | Language       | Licence                                           | Origin                                                                                                                                                                          | Usable?                                              |
| ---------------------------------------------- | -------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| openI1D3probeDriver (Neil Robinson, 2010) [O1] | C++, Windows   | Library: LGPL 2.1+. Utility: GPL v2.              | README: "inspired in part by the driver code from Argyll", plus Wireshark and firmware analysis. Ships an X-Rite firmware `.hex` and lock "signature" files. Can write EEPROMs. | No. Derived from GPL code; contains vendor firmware. |
| MinimalArgyllRustLib [O2]                      | Rust           | AGPL-3.0                                          | "A minimal rewrite of ArgyllCMS i1d3"                                                                                                                                           | No.                                                  |
| calibrate-pro [O3]                             | Python         | FSL-1.1-MIT ("Source-available, not open source") | Contains the retail key; origin not stated.                                                                                                                                     | No. FSL is not permissive until it converts.         |
| i1d3_hook (ledoge) [O4]                        | C, Windows DLL | GPL-3.0                                           | Hooks the official i1d3 SDK DLL to unlock OEM variants.                                                                                                                         | No.                                                  |
| HCFR (`hcfr-code`) [O5]                        | C/C++          | GPL-2.0                                           | Vendors Argyll's `Tools/spectro/i1d3.c`.                                                                                                                                        | No.                                                  |
| ChromIQ [O6]                                   | C              | GPL-3.0                                           | Vendors Argyll's `instlib/i1d3.c`.                                                                                                                                              | No.                                                  |

No MIT, BSD, Apache or Swift implementation of the i1d3 protocol was found.

### 1.4 Official SDK

- X-Rite's "SDK/API License" page lists an SDK for "i1D3 OEM Colorimeters". You request it from a My X-Rite account with the "Request SDK" button. Terms and price are not public [V6].
- X-Rite's OEM page defines three device kinds [V5]:
  - Standard (retail, part `EODIS3-XR`): "sold as a solution and only supports X-Rite applications software".
  - OEM Generic: "support any software that implements support for the OEM Generic device"; does not work with X-Rite software.
  - Custom OEM-branded: works only with that OEM's software.
  - Third-party developers "purchase licensing for X-Rite device connections".
- The i1D3HL OEM page lists Calman, Wacom, ViewSonic, BenQ, Dell, Calibrite, ASUS, Kodak and Qubyx as supporting software [V4].
- The SDK ships as a Windows DLL named `i1d3SDK.dll` or `i1d3.dll` [O4]; LightSpace shipped `i1D3SDK.dll` in 2013 [O8]. A macOS build of the SDK and its compatibility with the App Sandbox are UNCONFIRMED. A Calibrite-run developer programme was not found (UNCONFIRMED).
- Implication: the licensed SDK is the fully sanctioned path, but it needs a commercial agreement and a closed binary.

### 1.5 What other software does

| Software                     | How it drives the i1d3                                                                                                   | Source    |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------ | --------- |
| DisplayCAL                   | GPL-3.0 GUI that runs ArgyllCMS command-line tools (`spotread`, `dispread`). No driver of its own.                       | [D6] [D2] |
| HCFR                         | GPL-2.0. Compiles in a copy of Argyll's `i1d3.c`.                                                                        | [O5]      |
| LightSpace / ColourSpace     | Commercial. Uses the X-Rite SDK DLL (forum, 2013).                                                                       | [O8]      |
| Calman (Portrait Displays)   | Commercial. X-Rite lists it as OEM software for the i1D3 OEM and i1D3HL OEM.                                             | [V4]      |
| Calibrite PROFILER           | Vendor software.                                                                                                         | [V1]      |
| Apple Pro Display Calibrator | First-party Apple app; lists "Calibrite: Display Plus HL" as a supported instrument. This is not an App Store precedent. | [V10]     |

### 1.6 Conclusion: the smallest viable legal path, and the clean-room discipline

Path: a clean-room Swift driver that talks to the device over HID. It implements only the read-only commands in section 3, the EEPROM decoding in section 4, and the matrix math in sections 4 and 5. No third-party code or data.

Clean-room rules (copyright hygiene; this is not legal advice):

1. Roles. The spec author (who wrote this document) has read GPL sources. The implementer must not read, open or search the source of ArgyllCMS, HCFR, openI1D3, MinimalArgyllRustLib, calibrate-pro, ChromIQ or i1d3_hook, before or during implementation. Do not open them "for reference".
2. Inputs. The implementer may use this spec, Apple documentation, the USB HID specification, the CIE data tables, and black-box observation of a real device. Running ArgyllCMS's `spotread` as a black-box reference meter is fine. Reading its source is not.
3. No translation. Do not translate any of those projects line by line. Structure the Swift code from Swift idioms, not from C.
4. Facts are fine. Opcodes, byte offsets, numeric keys, the unlock arithmetic, EEPROM layouts and test vectors are functional facts. This spec restates them in its own words.
5. Provenance. Store this spec's commit hash in the implementation issue, plus a one-line statement from the implementer that they followed rules 1–3.

Legal risks that the clean room does not remove (needs counsel review before release):

- The lock is a technical measure that X-Rite uses to restrict which software can drive a given unit [V5]. 17 U.S.C. §1201(f) allows circumvention "solely for the purpose" of interoperability of an independently created program, under conditions [L3]. Whether the unlock in section 3.5 falls under that exception, and how X-Rite's licensing position applies, is a legal question.
- X-Rite asked ArgyllCMS to remove C6 (Calman) support, and Argyll did so "as a favor" [A2 `log.txt`]. Expect X-Rite or OEMs to object to unlocking their branded units.
- Recommendation: ship only the keys for the products the app targets (retail, ColorMunki and generic OEM, section 3.6). Do not ship the keys of vendor-branded units (NEC, Quato, HP, Wacom, Toshiba, Barco, PhotoCrysta, ViewSonic).

## 2. USB identity and transport

### 2.1 Vendor and product IDs

| VID      | PID                          | Device                                                                             | Source                                                                                                                     |
| -------- | ---------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `0x0765` | `0x5020`                     | "i1DisplayPro, ColorMunki Display (HID)": the whole i1d3 family                    | [A2 `spectro/insttypes.c`], [A2 `usb/55-Argyll.rules`] ("i1Display 3", colord kind `i1-display3`), [U1] ("i1 Display Pro") |
| `0x0765` | `0x5001`, `0x5010`           | HueyL (laptop-embedded Huey); usb.ids names `0x5010` "X-Rite Pantone Color Sensor" | [A2 `spectro/insttypes.c`], [U1]                                                                                           |
| `0x0765` | `0x6003`                     | ColorMunki Smile (not i1d3)                                                        | [A2 `spectro/insttypes.c`]                                                                                                 |
| `0x0765` | `0x6008`, `0x6009`           | i1Studio, i1Pro 3 (spectrometers)                                                  | [A2 `spectro/insttypes.c`]                                                                                                 |
| `0x0765` | `0xD020`, `0xD092`, `0xD094` | DTP20, DTP92Q, DTP94                                                               | [A2 `spectro/insttypes.c`]                                                                                                 |
| `0x0971` | various                      | Old GretagMacbeth devices (i1Pro, i1 Display 2, Huey)                              | [A2 `spectro/insttypes.c`]                                                                                                 |

- `0x5020` is the only i1d3 PID in ArgyllCMS V3.5.0, and Argyll is reported to work with both HL models [D1] [D2]. So both HL models enumerate as `0765:5020` by inference. UNCONFIRMED until checked with `ioreg` (section 6.6).
- The variant (retail, OEM, ColorMunki, HL) is not visible in the USB IDs. The product name, product type, serial number prefix and the key that unlocks the unit tell them apart.
- openI1D3's README says a corrupted internal EEPROM makes the unit report "a different USB Vendor ID" [O1]. This is one more reason never to write to the device.

### 2.2 HID transport

- The device is a USB HID-class device; no driver is needed [A2 `spectro/i1d3.c`] [D2].
- ArgyllCMS describes a 64-byte command and response buffer, "communicating over EP 0x81 and 0x01" [A2 `spectro/i1d3.c`]. The endpoint transfer type is not stated (interrupt is assumed for HID; UNCONFIRMED).
- Report IDs are not used. Argyll's Windows path prepends a `0x00` report-ID byte before the 64 data bytes [A2 `spectro/hidio.c`]. So the report payload is exactly the 64-byte command, and byte 0 is the command code, not a report ID.
- Host to device: output report. Argyll's macOS code sends it with the legacy `IOHIDDeviceInterface` `setReport(kIOHIDReportTypeOutput, …)` and passes report ID 9, which the device evidently ignores [A2 `spectro/hidio.c`]. Use "no report ID" (CoreHID: `id: nil`; CoreHID treats report ID 0 as invalid [P10]).
- Device to host: input report, delivered to an interrupt-report callback. Argyll notes that polling with `GetReport(kIOHIDReportTypeInput)` "doesn't work" and returns `kIOUSBPipeStalled` [A2 `spectro/hidio.c`]. Do not poll with get-report. Use the input-report stream.
- Argyll opens the device with `kIOHIDOptionsTypeSeizeDevice` [A2 `spectro/hidio.c`].
- HID usage page and usage: UNCONFIRMED. No public report descriptor was found. Match on VID and PID only, not on usage.

### 2.3 macOS API choice (recommendation)

The app targets macOS 15, so use CoreHID (introduced in macOS 15.0 [P7]). Its async API fits Swift 6 strict concurrency, and Apple DTS calls it "the modern API for this" [P4].

- Discovery: `HIDDeviceManager.monitorNotifications(matchingCriteria:)` with vendor ID `0x0765` and product ID `0x5020` [P12].
- Connection: `HIDDeviceClient(deviceReference:)`. Optionally call `seizeDevice()`; it throws `exclusiveAccess` if another client holds the device and `busy` if calls are outstanding [P8].
- Send: `dispatchSetReportRequest(type: .output, id: nil, data: 64 bytes, timeout:)` [P9].
- Receive: `monitorNotifications(reportIDsToMonitor: [.allReports], elementsToMonitor: [])`, then take `.inputReport` notifications [P11] [P10].
- Keep exactly one command in flight. One actor owns the client and serializes `send → await next input report`.
- CoreHID's get-report also goes through `IOHIDLibUserClient` [P6], so the sandbox rule in section 6 applies to it too.
- Fallback for older systems: `IOHIDManager` plus `IOHIDDeviceSetReport` and `IOHIDDeviceRegisterInputReportCallback`. Behaviour is the same.

## 3. Protocol specification

### 3.1 Framing

Request, host to device: 64 bytes, zero-filled before use.

| Byte | Meaning                                                                                             |
| ---- | --------------------------------------------------------------------------------------------------- |
| 0    | Command code ("major code").                                                                        |
| 1    | Sub-command when byte 0 is `0x00`. For all other commands, the first parameter byte.                |
| 2–63 | Parameters. Multi-byte integers are little-endian, except the external EEPROM address (big-endian). |

Response, device to host: 64 bytes.

| Byte | Meaning                                                                                                                                                                                                                 |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0    | Status. `0x00` = OK. `0x83` = Rev. B period/AIO measurement found no light transitions in its window (treat as "dark", see 4.5). `0x81` was seen after a measurement and is guessed to mean "too bright" (UNCONFIRMED). |
| 1    | Echo of byte 0 of the request (so `0x00` for the `0x00xx` group). Exceptions: `0x94` returns the diffuser position here, and `0x10` is not checked.                                                                     |
| 2–63 | Payload.                                                                                                                                                                                                                |

Validation and recovery [A2 `spectro/i1d3.c`]:

- Reject a reply if its length is not 64, its status is not `0x00`, or its echo does not match (except `0x94` and `0x10`).
- For `0x94`, bytes 2–63 must all be zero.
- After any failure (send error, timeout, bad status, bad echo), read and discard one pending input report with a 0.2 s timeout. This resynchronizes request and reply.

Timeouts [A2 `spectro/i1d3.c`]: 1.0 s for information, EEPROM, LED and unlock commands; 0.5 s for `0x10`; 40 s for measurement commands.

### 3.2 Command table (read-only allowlist)

| Name                                             | Byte 0 | Byte 1                        | Other request bytes                                                                                                                                                             | Reply payload                                                                                                                                                                        | Timeout |
| ------------------------------------------------ | ------ | ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------- |
| Get info                                         | `0x00` | `0x00`                        | –                                                                                                                                                                               | ASCII, NUL-terminated, from byte 2: product name, firmware version and date in one string                                                                                            | 1 s     |
| Get status                                       | `0x00` | `0x01`                        | –                                                                                                                                                                               | Byte 2 (u8) and bytes 3–4 (u16 LE). "OK" if byte 2 ≠ 0 or the u16 ≥ 5. Meaning otherwise unknown. Abort init if not OK.                                                              | 1 s     |
| Get product name                                 | `0x00` | `0x10`                        | –                                                                                                                                                                               | ASCII from byte 2, at most 31 chars. Examples: `"i1Display3 "`, `"ColorMunki Display"`.                                                                                              | 1 s     |
| Get product type                                 | `0x00` | `0x11`                        | –                                                                                                                                                                               | u16 LE at bytes 3–4. `0x0001` = i1Display Pro, `0x0002` = ColorMunki Display. Other values UNCONFIRMED.                                                                              | 1 s     |
| Get firmware version                             | `0x00` | `0x12`                        | –                                                                                                                                                                               | ASCII from byte 2, for example `"v1.0 "`                                                                                                                                             | 1 s     |
| Get firmware date                                | `0x00` | `0x13`                        | –                                                                                                                                                                               | ASCII from byte 2, for example `"11Jan11"`                                                                                                                                           | 1 s     |
| Get lock status                                  | `0x00` | `0x20`                        | –                                                                                                                                                                               | Locked if byte 2 = 0 and byte 3 ≠ 0. Otherwise unlocked.                                                                                                                             | 1 s     |
| Get firmware number (Rev. B only)                | `0x00` | `0x31`                        | –                                                                                                                                                                               | u16 LE at bytes 3–4. On Rev. A this returns a string instead, so call it only after `0x10` succeeded.                                                                                | 1 s     |
| Get more hardware info (Rev. B only)             | `0x10` | `0x00`                        | –                                                                                                                                                                               | Byte 2 = two 4-bit values (meaning UNCONFIRMED). Fails on Rev. A, so use it as the Rev. B probe. No echo check.                                                                      | 0.5 s   |
| Frequency measure                                | `0x01` | param                         | Bytes 1–4: integration time in 12 MHz clocks, u32 LE. Byte 23 = 0.                                                                                                              | Counts R, G, B as u32 LE at bytes 2, 6, 10. Both edges of the sensor signal are counted.                                                                                             | 40 s    |
| Period measure                                   | `0x02` | param                         | Bytes 1–2, 3–4, 5–6: edge counts R, G, B (u16 LE, 1–65535; use even values ≥ 2). Byte 7: channel mask (bit 0 R, bit 1 G, bit 2 B). Byte 8 = 0.                                  | 12 MHz clock counts R, G, B as u32 LE at bytes 2, 6, 10. 0 = no edges within about 10 s (Rev. A). Rev. B returns status `0x83` instead.                                              | 40 s    |
| AIO measure (Rev. B, firmware number ≥ `0x021A`) | `0x04` | param                         | Bytes 1–4: integration time in 12 MHz clocks, u32 LE (keep ≤ 6 s). Byte 5 = 0. Byte 6 = `0x07`. Bytes 7–8 = 1000 (u16 LE). Meaning of bytes 6–8 UNCONFIRMED; send these values. | Counts R, G, B as u32 LE at bytes 2, 6, 10. 48 MHz clock counts R, G, B as u32 LE at bytes 14, 18, 22. Flags (u8) at bytes 26, 27, 28 (meaning UNCONFIRMED). Status `0x83` possible. | 40 s    |
| Read internal EEPROM                             | `0x08` | address (0–255)               | Byte 2: length (1–60)                                                                                                                                                           | Data from byte 4                                                                                                                                                                     | 1 s     |
| Read external EEPROM                             | `0x12` | address high byte             | Byte 2: address low byte (address 0–8191, big-endian). Byte 3: length (1–59).                                                                                                   | Data from byte 5                                                                                                                                                                     | 1 s     |
| Set LED                                          | `0x21` | mode: 1 = on/off, 3 = fade on | Byte 2: off time. Byte 3: on time. Byte 4: pulse count (`0x80` = endless). Times clamp to 0–255 ticks.                                                                          | –                                                                                                                                                                                    | 1 s     |
| Get diffuser position                            | `0x94` | –                             | –                                                                                                                                                                               | Byte 1: 0 = display (emissive) position, 1 = ambient diffuser over the sensor. Bytes 2–63 are zero.                                                                                  | 1 s     |
| Get unlock challenge                             | `0x99` | –                             | –                                                                                                                                                                               | 64-byte challenge (section 3.5)                                                                                                                                                      | 1 s     |
| Send unlock response                             | `0x9A` | –                             | Response bytes at 24–39 (section 3.5)                                                                                                                                           | Byte 2 = `0x77` on success                                                                                                                                                           | 1 s     |

Source for the whole table: [A2 `spectro/i1d3.c`]. openI1D3 [O1] uses the same codes and layouts for `0x00`, `0x08`, `0x12`, `0x01`, `0x02`, `0x04`, `0x21`, `0x94`, `0x99` and `0x9A`, which is an independent cross-check.

LED timing: one off-time tick (and one on-time tick in mode 1) is 2^19 / 12 MHz = 43.69 ms. One on-time tick in mode 3 (fade) is 2^23 / 12 MHz = 0.699 s [A2 `spectro/i1d3.c`]. Examples: steady on = mode 1, off 0, on 255, count `0x80`. Steady off = mode 1, off 255, on 0, count `0x80`. Argyll's "connected" blink = mode 1, off 5 ticks (0.2 s), on 1 tick (0.05 s), count 2.

Temperature: no temperature command is known. Code `0x93` ("read the analog sensor") and code `0x9B` ("close device – relock?") are named in ArgyllCMS but never sent, and their layouts are unknown [A2 `spectro/i1d3.c`]. Do not use them (UNCONFIRMED).

### 3.3 Forbidden commands

Send only the codes in the table above. Public tooling uses these write codes [O1]:

| Code   | Use in openI1D3                                     |
| ------ | --------------------------------------------------- |
| `0x07` | Write internal EEPROM (32-byte chunks)              |
| `0x13` | Write external EEPROM                               |
| `0xAB` | "Enable write access" with a 4-byte magic parameter |

The external EEPROM holds the per-unit calibration and the "signature" that selects which key unlocks the unit [O1]. Writing can make the unit unusable or change its identity. The driver must contain no code path that can send these bytes.

### 3.4 Device revisions

- Hardware revision letter: first character of the version string in internal EEPROM at `0x2C` (`"A-01"`, `"A-02"`, `"B-02"`). `'A'` = Rev. A, `'B'` = Rev. B [A2 `spectro/i1d3.c`].
- Rev. B probe: command `0x10` succeeds only on Rev. B. Then command `0x00 0x31` returns the firmware number. AIO (`0x04`) needs a firmware number ≥ `0x021A` [A2 `spectro/i1d3.c`].
- Rev. B adds the AIO measurement mode, and Rev. B OEM units made from 2017 were "certified to 2000 nits" after a hardware upgrade [V9].
- The revision and firmware number of the HL models are UNCONFIRMED. Log them.

### 3.5 Unlock algorithm

Inputs: a key of two 32-bit words `k0`, `k1` (section 3.6), and the 64-byte challenge `c` returned by command `0x99`. All arithmetic on 32-bit words is modulo 2^32. All arithmetic on bytes is modulo 256.

Steps:

1. Unmask 8 challenge bytes: `s[i] = c[3] XOR c[35 + i]` for `i = 0…7`.
2. Pack two 32-bit words from them, most significant byte first:
   - `a = s[3], s[0], s[4], s[6]` (that is, `s[3] << 24 | s[0] << 16 | s[4] << 8 | s[6]`)
   - `b = s[1], s[7], s[2], s[5]`
3. Negate the key words: `n0 = −k0`, `n1 = −k1` (mod 2^32).
4. Four products and differences:
   - `p0 = n0 − b`
   - `p1 = n1 − a`
   - `p2 = b × n0`
   - `p3 = a × n1`
5. Checksum: `sum = s[0] + … + s[7] + (the 4 bytes of n0) + (the 4 bytes of n1)`, as a plain integer (at most 4080). Let `lo = sum & 0xFF` and `hi = (sum >> 8) & 0xFF`.
6. Build 16 bytes `r[0…15]`. `byte(x, j)` means `(x >> 8j) & 0xFF`. Each entry is mod 256:

   | i   | r[i]             | i   | r[i]             |
   | --- | ---------------- | --- | ---------------- |
   | 0   | byte(p0, 2) + lo | 8   | byte(p3, 1) + lo |
   | 1   | byte(p2, 1) − hi | 9   | byte(p2, 3) − hi |
   | 2   | byte(p3, 0) + hi | 10  | byte(p0, 1) + lo |
   | 3   | byte(p1, 2) + lo | 11  | byte(p1, 1) − hi |
   | 4   | byte(p2, 2) − hi | 12  | byte(p1, 0) + hi |
   | 5   | byte(p3, 2) − lo | 13  | byte(p3, 3) + hi |
   | 6   | byte(p1, 3) − lo | 14  | byte(p2, 0) + lo |
   | 7   | byte(p0, 0) − hi | 15  | byte(p0, 3) − lo |

7. Response request: 64 zero bytes, byte 0 = `0x9A`, bytes `24 + i` = `c[2] XOR r[i]` for `i = 0…15`. The vendor driver fills the other bytes with random data, but the device ignores them, so zeros work [A2 `spectro/i1d3.c`].
8. Send it. Byte 2 of the reply = `0x77` means the key was accepted. Then confirm with "Get lock status" (must report unlocked).

Pseudocode:

```text
func unlockResponse(k0: UInt32, k1: UInt32, c: [UInt8; 64]) -> [UInt8; 64]
    s[i]  = c[3] ^ c[35+i]                          for i in 0..<8
    a     = s3<<24 | s0<<16 | s4<<8 | s6
    b     = s1<<24 | s7<<16 | s2<<8 | s5
    n0    = 0 &- k0 ;  n1 = 0 &- k1
    p0    = n0 &- b ;  p1 = n1 &- a
    p2    = b &* n0 ;  p3 = a &* n1
    sum   = Σ s[i] + Σ bytes(n0) + Σ bytes(n1)       // plain Int
    lo, hi = sum & 0xFF, (sum >> 8) & 0xFF
    r     = table of step 6, wrapping UInt8 arithmetic
    out   = [0; 64];  out[0] = 0x9A
    out[24+i] = c[2] ^ r[i]                          for i in 0..<16
```

Unlock procedure: for each key in order, get a fresh challenge (`0x99`), send the response (`0x9A`), check byte 2 = `0x77`, then check the lock status. Stop at the first success. If all keys fail, report "unsupported OEM variant". ArgyllCMS tries all its keys this way, without delays, regardless of product name [A2 `spectro/i1d3.c`]. No lock-out after failed attempts is documented (UNCONFIRMED).

Test vectors. These came from the spec author's own implementation of the steps above, written from this prose, and they match the ArgyllCMS function output for the same inputs. The challenges are synthetic, not captured from a device:

```text
Challenge T0 (64 bytes):
0099557a9fc4e90e33587da2c7ec11365b80a5caef14395e83a8cdf2173c6186
abd0f51a3f6489aed3f81d42678cb1d6fb20456a8fb4d9fe23486d92b7dc0126
Challenge T1 (64 bytes):
0099f9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a2
9f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542

Expected response bytes 24..39:
T0, key #1 (e9622e9f, 8d63e133): 65c57460edfad0e4379df91607f25682
T0, key #2 (e01e6e0a, 257462de): 147219a4a3ab7510ef2f6f95fd867846
T0, key #3 (caa62b2c, 30815b61): 811a93aad734af767329cd9d70ba8358
T1, key #1:                      79f3a86cdf0e6410a4963d629b42d2ae
T1, key #2:                      6890d5abf218c184612babe141c4446a
T1, key #3:                      dd982f990e79eba26d1849d9cc1f2f74
Full request = 9a + 23 × 00 + (16 bytes above) + 24 × 00
```

### 3.6 Key table

From ArgyllCMS V3.5.0, in its try order [A2 `spectro/i1d3.c`]. The text form of a key is `k0` then `k1` as 16 hex digits; Argyll's `I1D3_ESCAPE` example is `e9622e9f8d63e133` for key #1 [A3].

| #   | ArgyllCMS label                 | k0           | k1           | Products (mapping notes)                                                                                                                                             |
| --- | ------------------------------- | ------------ | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | i1 DisplayPro (retail)          | `0xE9622E9F` | `0x8D63E133` | X-Rite i1Display Pro retail. Calibrite ColorChecker Display Pro by rebrand (UNCONFIRMED). One of the two candidates for both HL models [D1] [D2].                    |
| 2   | ColorMunki Display              | `0xE01E6E0A` | `0x257462DE` | ColorMunki Display. i1Display Studio and Calibrite ColorChecker Display likely (UNCONFIRMED). Argyll notes that a product type `0x0002` unit may not need unlocking. |
| 3   | i1 DisplayPro Plus, generic OEM | `0xCAA62B2C` | `0x30815B61` | i1Display Pro Plus and the OEM Generic i1D3. Calibrite ColorChecker Display Plus by rebrand (UNCONFIRMED). The other HL candidate [D1] [D2].                         |
| 4   | NEC SpectraSensor Pro           | `0xA9119479` | `0x5B168761` | Vendor-locked. Do not ship (section 1.6).                                                                                                                            |
| 5   | Quato Silver Haze 3             | `0x160EB6AE` | `0x14440E70` | Vendor-locked. Do not ship.                                                                                                                                          |
| 6   | HP DreamColor                   | `0x291E41D7` | `0x51937BDD` | Vendor-locked. Do not ship.                                                                                                                                          |
| 7   | Wacom DC                        | `0x1ABFAE03` | `0xF25AC8E8` | Vendor-locked. Do not ship.                                                                                                                                          |
| 8   | Toshiba TPA-1                   | `0x828C43E9` | `0xCBB8A8ED` | Vendor-locked. Do not ship.                                                                                                                                          |
| 9   | Barco                           | `0xE8D1A980` | `0xD146F7AD` | Vendor-locked. Do not ship.                                                                                                                                          |
| 10  | PhotoCrysta                     | `0x171AE295` | `0x2E5C7664` | Vendor-locked. Do not ship.                                                                                                                                          |
| 11  | ViewSonic CS-XRi1               | `0x64D8C546` | `0x4B24B4A7` | Vendor-locked. Do not ship.                                                                                                                                          |

HL: no source reports a different unlock procedure or a new key for the Display Plus HL or Display Pro HL. Which of keys #1 and #3 each HL model accepts is UNCONFIRMED. Log the index of the key that worked.

### 3.7 Initialization sequence

Order used by ArgyllCMS [A2 `spectro/i1d3.c`]:

1. Open (optionally seize) the device.
2. Get status. It must be "OK".
3. Get product name, then product type.
4. Get firmware version string.
5. Get more hardware info (`0x10`, 0.5 s timeout). On success: Rev. B, then get the firmware number (`0x00 0x31`). On failure: Rev. A, firmware number 0. Resynchronize after the failure (section 3.1).
6. Get firmware date.
7. Use AIO if the firmware number ≥ `0x021A`.
8. Get lock status. If locked: unlock (section 3.5) and confirm. If still locked: stop with "unsupported variant".
9. Read the internal EEPROM, addresses 0–255 (5 reads of at most 60 bytes).
10. Read the external EEPROM, addresses 0–8191 (139 reads of at most 59 bytes).
11. Decode both (section 4) and compute the default matrix.
12. Optional: blink the LED as "connected" feedback.

Notes:

- Argyll reads the EEPROMs only after the unlock. Whether reads work while locked is UNCONFIRMED, so unlock first.
- Recommendation: cache the decoded EEPROM per serial number. The calibration data does not change.
- Argyll polls the diffuser position every 100 ms in a background thread and pauses the poll during measurements [A2 `spectro/i1d3.c`]. Recommendation: check the position once before each measurement instead (that is enough for a TV workflow).
- On Windows, Argyll kills the vendor tray process (`i1ProfilerTray.exe`) because it holds the device [A2 `spectro/i1d3.c`]. On macOS the vendor's background process name is UNCONFIRMED. If the open or seize fails with exclusive access, tell the user to quit Calibrite PROFILER and DisplayCAL.

## 4. EEPROM data and conversion to XYZ

### 4.1 Internal EEPROM (256 bytes)

| Offset        | Size | Content                                                                                                                                           | Source                      |
| ------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| `0x00`        | 4    | Unknown                                                                                                                                           | –                           |
| `0x04`        | 4    | Black offset, red channel. u32 LE. `0xFFFFFFFF` = not set.                                                                                        | [A2 `spectro/i1d3.c`], [O1] |
| `0x08`        | 4    | Black offset, green channel                                                                                                                       | same                        |
| `0x0C`        | 4    | Black offset, blue channel                                                                                                                        | same                        |
| `0x10`        | 20   | Serial number, ASCII, not always NUL-terminated. Examples: `"I1-11.A-01.100999.02"`, `"CM-11.A-01.100999.02"`. OEM format `OE-yy.r-02.xxxxxx.mm`. | [A2 `spectro/i1d3.h`], [V9] |
| `0x24`        | 8    | Unknown                                                                                                                                           | –                           |
| `0x2C`        | 10   | Hardware version string, ASCII: `"A-01"`, `"A-02"`, `"B-02"`                                                                                      | [A2 `spectro/i1d3.h`]       |
| `0x36`–`0xFF` | –    | Unknown. Possibly USB identity data (see 2.1).                                                                                                    | [O1]                        |

Black offset units are UNCONFIRMED. The two sources disagree:

- ArgyllCMS converts the word to a frequency, `word / 6,000,000` Hz, and subtracts it from the measured frequency. Its decode loop also writes all three channels into the red slot, so in practice Argyll subtracts only the blue word, and from red [A2 `spectro/i1d3.c`].
- openI1D3 subtracts the raw word from frequency-mode raw counts (and has its own bug that uses the red value for blue) [O1].
- Recommendation: decode all three words and log them. If a word is `0xFFFFFFFF`, use 0. On hardware, compare dark readings (sensor face down on black cloth) with and without subtraction before you choose an interpretation. With Argyll's units, a typical word would change the reading by microhertz and would not matter.

### 4.2 External EEPROM (8192 bytes)

| Offset            | Size | Content                                                                                                                                                                                                                                    | Source                      |
| ----------------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------- |
| `0x0000`          | 2    | Unknown                                                                                                                                                                                                                                    | –                           |
| `0x0002`          | 2    | Checksum, u16 LE. For `"A-01"` units it is the sum of bytes `0x0004`–`0x1799`, mod 2^16. Later units often fail this check; sometimes the range `0x0004`–`0x178D` matches. Argyll fails only on `"A-01"` and ignores mismatches otherwise. | [A2 `spectro/i1d3.c`], [O1] |
| `0x0004`          | 26   | Unknown                                                                                                                                                                                                                                    | –                           |
| `0x001E`          | 8    | Calibration date, u64 LE. Encoding UNCONFIRMED (Argyll does not decode it).                                                                                                                                                                | [A2 `spectro/i1d3.c`]       |
| `0x0026`          | 1404 | Red sensor sensitivity: 351 × float32 LE                                                                                                                                                                                                   | [A2 `spectro/i1d3.c`], [O1] |
| `0x05A2`          | 1404 | Green sensor sensitivity: 351 × float32 LE                                                                                                                                                                                                 | same                        |
| `0x0B1E`          | 1404 | Blue sensor sensitivity: 351 × float32 LE                                                                                                                                                                                                  | same                        |
| `0x109A`          | 34   | Unknown                                                                                                                                                                                                                                    | –                           |
| `0x10BC`          | 1404 | Ambient diffuser transmission: 351 × float32 LE, unitless                                                                                                                                                                                  | [A2 `spectro/i1d3.c`], [O1] |
| `0x1638`–`0x1FFF` | –    | Unknown. Candidates: up to 4 factory 3×3 matrices "not usually set" (Argyll comment), the lock "signature" [O1], and on HL OEM units "18 reference device offset data matrixes" and a date/time [V4]. Locations UNCONFIRMED.               | –                           |

Sensor curves:

- 351 values per channel at 380, 381, …, 730 nm (1 nm step).
- Encoding: IEEE-754 binary32, little-endian. In Swift: `Float(bitPattern: UInt32(littleEndian: word))`. Argyll's decoder is a plain IEEE-754 decode, including subnormals [A2 `numlib/numsup.c`].
- Units: Argyll treats the stored values as "Hz per W/nm" and divides them by 1000 to get Hz per mW/nm [A2 `spectro/i1d3.c`]. Do the same; the matrix math in 4.4 relies on this scale.
- Ambient sensitivity = sensor sensitivity × diffuser transmission, per wavelength. Do not divide the transmission by 1000.

### 4.3 Raw readings to sensor frequency (Hz)

Clock: 12 MHz [A2 `spectro/i1d3.c`]. Integration clocks = `round(T × 12,000,000)`; then use the rounded time `T' = clocks / 12,000,000`.

| Mode               | Conversion                                                                                                                                                                                                                                                  | Source                |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| Frequency (`0x01`) | `Hz = 0.5 × n / T'`, where `n` is the count. If all three counts are non-zero, add 0.5 to each count first. Reason: the hardware starts counting in sync with the signal, so counts are biased down by 0 to 1. Argyll limits `T` to 20 s.                   | [A2 `spectro/i1d3.c`] |
| Period (`0x02`)    | `Hz = 0.5 × edges × 12,000,000 / clocks`. If `clocks` = 0, there is no reading.                                                                                                                                                                             | [A2 `spectro/i1d3.c`] |
| AIO (`0x04`)       | `Hz = 12,000,000 × (n − 1) / c48`, where `n` is the count and `c48` the 48 MHz clock count. (Argyll writes this as `(n − 1) × 0.25 / (c48 / 48,000,000)`; the 0.25 and the "− 1" were matched to the vendor driver and are not explained.) Guard `c48 = 0`. | [A2 `spectro/i1d3.c`] |

After conversion, for each channel:

1. Subtract the black offset (section 4.1) and clamp at 0.
2. Saturation check: if any channel is above 250,000 Hz, report "too bright". Argyll's comment says this "corresponds to 16000 cd/m^2" for the sensor it was written for [A2 `spectro/i1d3.c`]. Whether this limit is right for the HL sensor is UNCONFIRMED.

### 4.4 Sensor frequency to XYZ (the calibration matrix)

The device does not store a ready-made emissive matrix that Argyll uses. The host computes it from the sensor curves [A2 `spectro/i1d3.c`].

Definitions:

- `S_j(λ)`: sensor sensitivity of channel j (R, G, B), in Hz per mW/nm, at 380–730 nm.
- `x̄, ȳ, z̄`: CIE 1931 2° colour-matching functions at 360–830 nm in 1 nm steps. Get them from the CIE dataset `CIE_xyz_1931_2deg.csv`, DOI 10.25039/CIE.DS.xvudnb9b, licensed CC BY-SA 4.0 [L4]. Recommendation: ship the CSV unchanged as a resource file with attribution (it stays readable, unlike the encrypted executable), and ask counsel to confirm the share-alike terms.
- A "sample" is a spectrum `s(λ)`, either from a CCSS file or one of the sensor curves.

Value of a spectrum at wavelength λ, as ArgyllCMS does it [A2 `xicc/xspect.c`]:

- Clamp λ into the spectrum's own range (so values beyond the ends are held at the end value).
- If the spectrum's step is at most 5.01 nm: linear interpolation between the two neighbouring points.
- If the step is above 5.01 nm (for example a 10 nm CCSS): cubic Lagrange interpolation through 4 points, the two on each side, with the start index clamped to `[1, n−3]` so that the ends extrapolate from the end segments.
- Divide by `SPECTRAL_NORM` if the file has one (default 1).

Integrals (1 nm steps, as ArgyllCMS does) [A2 `xicc/xspect.c`, `spectro/i1d3.c`]:

```text
XYZ(s)   = 0.683002 × Σ_{λ = 360…830} s(λ) · (x̄, ȳ, z̄)(λ)        // cd/m² if s is in mW/(sr·m²·nm)
rgb_j(s) =            Σ_{λ = 380…730} s(λ) · S_j(λ)               // Hz
```

Matrix from N ≥ 3 samples. Stack the samples as rows: `X` is N×3 (row k = `XYZ(s_k)`) and `R` is N×3 (row k = `rgb(s_k)`). Find the 3×3 matrix `M` with `XYZ ≈ M · rgb`:

```text
N = 3:   M = (R⁻¹ · X)ᵀ
N > 3:   M = ((Rᵀ R)⁻¹ · Rᵀ X)ᵀ          // least squares (normal equations)
```

If `R` or `RᵀR` is singular, report an error ("too few independent samples").

Default calibration ("MIbLSr", maximum ignorance by least squares): use the three sensor curves themselves as the three samples, `s_k = S_k` [A2 `spectro/i1d3.c`]. Argyll says this "matches the OEM default calibrations". The result is the least-squares fit of the colour-matching functions by a linear mix of the sensor curves.

Result:

```text
XYZ (cd/m²) = C_ccmx · M · max(0, Hz − black)
```

`C_ccmx` is the identity unless a CCMX is active (section 5.2). When a CCSS is active, M is computed from the CCSS samples and `C_ccmx` is the identity.

Ambient mode (not needed for TV work): compute `M_amb` with the same MIbLSr method from the ambient sensitivities, and require diffuser position 1. Argyll labels the result as lux [A2 `spectro/i1d3.c`]; whether any extra factor applies is UNCONFIRMED.

Self-tests that need no hardware:

- MIbLSr: `M · rgb(S_k)` must equal `XYZ(S_k)` exactly for k = R, G, B.
- Scale invariance: multiplying every CCSS sample by a constant must not change M.
- Unlock: the test vectors in section 3.5.

### 4.5 Measurement strategy

Integration time defaults [A2 `spectro/i1d3.c`]: 0.2 s base. ArgyllCMS doubles it to 0.4 s in "refresh display" mode and rounds it up to a whole number of refresh periods. AIO integration is limited to 6 s.

AIO path (Rev. B, firmware number ≥ `0x021A`), as in ArgyllCMS:

```text
T0 = 0.2 s (or the frame-quantized value, see 4.6)
hz = AIO(T0)                 // on status 0x83: hz = (0, 0, 0)
cycles_i = hz_i × T0
if no channel has cycles_i > 4000 and some channel has cycles_i < 100:
    T2 = max over those channels of T0 × 100 / max(cycles_i, 1)
    T2 = min(T2, 6 s); round up to whole frames; if above 6 s, drop one frame
    hz = AIO(T2)
    on status 0x83: hz = 0.5 × count / T3 from a frequency measure with T3 = 10 s (frame-quantized)
subtract black, clamp at 0, saturation check
```

Note: Argyll stops scanning the channels at the first channel above 4000 cycles, and then skips the re-measure.

Legacy path (Rev. A, or AIO disabled), as in ArgyllCMS; needed only for old i1Display Pro units:

1. Frequency measure over T0. Convert to Hz. Saturation check.
2. Each channel with a count below 200 needs a better reading.
3. For such a channel with a count below 20 (below 10 on a ColorMunki Display), run a period pre-measure over 2 edges. On non-ColorMunki units, run a second pre-measure with the edge count set for about 0.1 s.
4. Per channel, choose a target time. If the expected edge count over T0 is below 200, lengthen the time along a square-root blend between "1 edge" and "200 edges", up to 6 s. Round up to whole frames. Use the largest time for all channels when it costs less than 10 % extra.
5. Edge count = even number from 2 to 65,534 that covers the target time.
6. If a refresh period is known and the smallest edge count is at least 100, use one frequency measure over the target time. Otherwise run a period measure with those edge counts. If a channel returns 0 clocks, use its pre-measure estimate.
7. On status `0x83`, fall back to a 10 s frequency measure.

Recommendation (smallest complete driver): implement AIO plus the frequency fallback. HL units are new hardware, so they are probably Rev. B with AIO (UNCONFIRMED). Add the legacy period path only if the app must support Rev. A i1Display Pro units, and verify on such a unit.

Non-adaptive mode: a single frequency measure over a fixed time. Faster, but less accurate at low light [A7].

### 4.6 Refresh rate and display update delay

Two different things:

- AIO is the Rev. B measurement command (section 3.2). It is not a refresh-rate feature.
- "Refresh mode" is an ArgyllCMS display-type flag. It doubles the integration time to 0.4 s and rounds it to whole refresh periods. ArgyllCMS classifies "LED OLED", "LED AMOLED" and "LED WOLED" as non-refresh displays [A2 `spectro/disptechs.c`], so it would measure an LG OLED with 0.2 s and no refresh quantization.

ArgyllCMS refresh-rate detection (summary): it takes up to 1300 frequency readings (about 6 s at most) with random integration times between 0.3 ms and 4 ms, timestamps each one, autocorrelates the readings at lags from 25 ms to 200 ms, smooths the result, finds the peaks and derives a common period. It requires a total RMS signal of at least 1000 and a correlation contrast of at least 10 % [A2 `spectro/i1d3.c`].

Recommendation: do not implement detection. The app generates the patterns and knows the frame rate of the signal (for example 60, 120, 50 or 24 Hz). Round integration times up to whole frame periods from that known rate. Example: 0.2 s is exactly 12 frames at 60 Hz and 10 frames at 50 Hz, but 4.8 frames at 24 Hz, so use 0.25 s (6 frames) at 24 Hz.

Display update delay, as ArgyllCMS measures it [A2 `spectro/i1d3.c`] [A3]:

1. Show black. Start repeated 5 ms frequency measures and timestamp each one (at most 400 readings or 2 s).
2. Switch the pattern to white and record the switch time.
3. Sum R+G+B per reading. Take the maximum of the first 100 ms as "start" and the maximum of the last 100 ms as "end".
4. The delay is the first time after the switch when the sum exceeds start + 20 % of (end − start). If end − start is below 10 counts, report "no transition".

ArgyllCMS's default minimum patch delay is 200 ms, and it measures the update delay automatically for the i1d3 [A3]. Recommendation: run this once per session over the real pattern path (Mac or Apple TV to the TV), because the TV's processing latency depends on the picture mode.

### 4.7 HL models: extended luminance range

| Model                                          | Rated maximum          | Source    |
| ---------------------------------------------- | ---------------------- | --------- |
| i1Display Pro (retail)                         | 0.1–1000 cd/m²         | [V8]      |
| i1Display Pro Rev. B OEM, 2017 and later       | certified to 2000 nits | [V9]      |
| i1Display Pro Plus / ColorChecker Display Plus | 2000 nits              | [V7] [V3] |
| Display Pro HL / i1D3HL OEM                    | 3000 nits              | [V2] [V4] |
| Display Plus HL                                | 10,000 nits            | [V1]      |

- Calibrite says both HL models use an "HL (high luminance) sensor" [V1] [V2]. A DisplayCAL forum administrator says the HL is the same device as older versions "with modified gains", with worse low-light readings on OLED [D1]. A forum user says the newer meters keep the same sensor and add a filter for higher peak brightness, "meaning it's less sensitive to low light patterns" [D7] (user claim, UNCONFIRMED).
- Conversion: the per-unit sensor curves in EEPROM carry the gain, so the math in 4.3 and 4.4 should not change. ArgyllCMS has no HL-specific conversion and is reported to work [D1] [D2]. One user reported white points 200–300 K higher with DisplayCAL than with Calibrite PROFILER on a Display Pro HL [D1]. The cause is UNCONFIRMED.
- Whether the Display Plus HL and Display Pro HL differ in hardware or only in firmware or rating is UNCONFIRMED. Whether the protocol can tell them apart (product name, product type, serial prefix, key) is UNCONFIRMED.
- The 250,000 Hz saturation limit in 4.3 comes from older sensors. Its luminance equivalent on HL units is UNCONFIRMED.

## 5. Colorimeter corrections

### 5.1 How a CCSS changes the calibration

A CCSS holds spectral samples of one display type, normally the display's primaries and white measured with a reference spectroradiometer. ArgyllCMS uses them in place of the sensor curves as the samples of section 4.4 [A2 `spectro/i1d3.c`]:

```text
X (N×3): row k = XYZ(s_k) with the chosen observer (default CIE 1931 2°)
R (N×3): row k = rgb(s_k) with this unit's own sensor curves
M = (R⁻¹ X)ᵀ for N = 3, or ((RᵀR)⁻¹ RᵀX)ᵀ for N > 3
```

- The fit is exact for any light that is a linear mix of the samples, which is the case for a 3-primary display. Because the unit's own curves are used, one CCSS works on every i1d3 unit.
- The absolute scale of the samples does not matter (section 4.4).
- At least 3 samples are needed [A2 `xicc/ccss.c`].
- ArgyllCMS also allows other observers (for example its `ref/oled.cmf`, from Ko et al.) [A2 `ref/oled.cmf`]. That file is in the AGPL `ref/` directory, so do not embed it.

### 5.2 CCMX

A CCMX is a 3×3 matrix made for one colorimeter model and one display, applied after the instrument's own calibration [A2 `xicc/ccmx.c`]:

```text
XYZ_corrected = C · XYZ_instrument,   C[i][j] = value j of data set i (XYZ_X, XYZ_Y, XYZ_Z)
```

- For the i1d3, the instrument calibration under a CCMX is the default MIbLSr matrix of the base display type named by `DISPLAY_TYPE_BASE_ID` (1 = non-refresh, 2 = refresh; the two differ only in refresh mode) [A2 `spectro/i1d3.c`].
- ArgyllCMS maps these `INSTRUMENT` strings to the i1d3: `Xrite i1 DisplayPro`, `X-Rite i1 DisplayPro`, `ColorMunki Display`, `X-Rite i1 DisplayPro, ColorMunki Display`, `Xrite i1 DisplayPro, ColorMunki Display` [A2 `spectro/insttypes.c`]. Reject a CCMX made for another instrument.

### 5.3 CGATS file format for `.ccss` and `.ccmx` (enough for a parser)

General syntax (CGATS.17 style, as ArgyllCMS writes and reads it) [A2 `xicc/ccss.c`, `xicc/ccmx.c`, `cgats/cgats.c`]:

- Tokens are separated by spaces, tabs, CR or LF. A value is either a bare token or a string in double quotes.
- `#` starts a comment that runs to the end of the line (outside quotes).
- The first token is the file type: `CCSS` or `CCMX` (Argyll pads it with spaces, for example `CCSS   `).
- Header: `NAME value` pairs. Non-standard names are declared first with `KEYWORD "NAME"`. Accept a keyword with or without that declaration.
- `NUMBER_OF_FIELDS n`, then `BEGIN_DATA_FORMAT`, then n field names (they may span lines), then `END_DATA_FORMAT`.
- `NUMBER_OF_SETS m`, then `BEGIN_DATA`, then m rows of n values, then `END_DATA`.
- Numbers are decimal and may have an exponent or a minus sign (`-7.3700e-04`).

CCSS keywords [A2 `xicc/ccss.c`]:

| Keyword                               | Required         | Meaning                                                                                                    |
| ------------------------------------- | ---------------- | ---------------------------------------------------------------------------------------------------------- |
| `SPECTRAL_BANDS`                      | yes              | Number of wavelengths                                                                                      |
| `SPECTRAL_START_NM`                   | yes              | First wavelength (nm)                                                                                      |
| `SPECTRAL_END_NM`                     | yes              | Last wavelength (nm)                                                                                       |
| `SPECTRAL_NORM`                       | no (default 1.0) | Divide values by this                                                                                      |
| `DESCRIPTOR`, `ORIGINATOR`, `CREATED` | no               | Free text                                                                                                  |
| `DISPLAY`                             | no               | Display make and model                                                                                     |
| `TECHNOLOGY`                          | no               | Display technology string, for example `LCD White LED`, `LED OLED`, `LED WOLED` [A2 `spectro/disptechs.c`] |
| `DISPLAY_TYPE_REFRESH`                | no               | `YES` or `NO`                                                                                              |
| `UI_SELECTORS`                        | no               | Argyll's short menu selectors                                                                              |
| `REFERENCE`                           | no               | Reference instrument                                                                                       |
| `OEM`                                 | no               | `YES` or `NO`                                                                                              |

CCSS fields: `SAMPLE_ID`, then one field per wavelength named `SPEC_` plus the wavelength rounded to the nearest integer nm, zero-padded to 3 digits. For band j: `nm = round(start + j × (end − start) / (bands − 1))`. Example: 118 bands from 350 to 740 nm gives `SPEC_350 SPEC_353 SPEC_357 …` [A2 `ref/CRT.ccss`]. Each data set is one spectrum. At least 3 sets are needed.

CCMX keywords [A2 `xicc/ccmx.c`]:

| Keyword                                                                                                                    | Required | Meaning                                     |
| -------------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------- |
| `COLOR_REP`                                                                                                                | yes      | Must be `XYZ`                               |
| `INSTRUMENT`                                                                                                               | yes      | Colorimeter the matrix is for (section 5.2) |
| `DISPLAY_TYPE_BASE_ID`                                                                                                     | no       | Integer base display type (i1d3: 1 or 2)    |
| `DESCRIPTOR`, `DISPLAY`, `TECHNOLOGY`, `DISPLAY_TYPE_REFRESH`, `UI_SELECTORS`, `REFERENCE`, `OEM`, `ORIGINATOR`, `CREATED` | no       | As for CCSS                                 |

CCMX fields: `XYZ_X XYZ_Y XYZ_Z`, real numbers, exactly 3 sets; set i is matrix row i.

Minimal CCSS shape (values shortened):

```text
CCSS

DESCRIPTOR "Example"
KEYWORD "TECHNOLOGY"
TECHNOLOGY "LED WOLED"
KEYWORD "SPECTRAL_BANDS"
SPECTRAL_BANDS "36"
KEYWORD "SPECTRAL_START_NM"
SPECTRAL_START_NM "380.000000"
KEYWORD "SPECTRAL_END_NM"
SPECTRAL_END_NM "730.000000"

NUMBER_OF_FIELDS 37
BEGIN_DATA_FORMAT
SAMPLE_ID SPEC_380 SPEC_390 … SPEC_730
END_DATA_FORMAT

NUMBER_OF_SETS 4
BEGIN_DATA
1 0.0012 0.0019 … 0.0004
…
END_DATA
```

### 5.4 WOLED (LG OLED) correction sources and their terms

| Source                                                                  | What exists                                                                                                                                                                                                                                                                           | Terms                                                                              | Embed in the app?                                                                                    |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| ArgyllCMS `ref/`                                                        | Only `CRT.ccss` (no WOLED), plus the `oled.cmf` observer                                                                                                                                                                                                                              | AGPL v3 directory licence [A2 `ref/License.txt`]                                   | No                                                                                                   |
| ArgyllCMS website, contributed CCSS                                     | One file (MacBook Pro Retina 2016); no WOLED                                                                                                                                                                                                                                          | Contributions "will be assumed to have been placed in the public domain" [A5]      | Not useful                                                                                           |
| DisplayCAL Colorimeter Corrections Database                             | User-uploaded CCSS and CCMX. Query API `?get=1&type=ccss&display=…`. WOLED coverage UNCONFIRMED (the site was blocked by Cloudflare during this research).                                                                                                                            | "Any uploaded files will be assumed to have been placed in the public domain" [D5] | Not recommended: provenance of each upload is unverified (some may derive from proprietary EDR data) |
| DisplayCAL bundled `LG OLED 6-Series (i1 Pro 2, ColorMunki Photo).ccss` | The WOLED correction DisplayCAL's administrator recommends, made in the TV's native gamut [D3]                                                                                                                                                                                        | Bundled with GPL-3 DisplayCAL; the data's own licence is UNCONFIRMED               | No                                                                                                   |
| X-Rite / Calibrite EDR files                                            | Vendor spectral sets shipped with i1Profiler / Calibrite PROFILER. A WRGB OLED EDR (`FSI_XM55U_23Jan19.edr`) is not in i1Profiler but ships with LightSpace, and was made in Rec. 709 emulation mode [D3]. ArgyllCMS `oeminst` converts EDR to CCSS from the user's own install [A4]. | Proprietary                                                                        | No. User-supplied import at most, after legal review.                                                |
| Calman "OLED TV (WRGB)" meter mode                                      | Improved LG 42C2 greyscale from 1.6 to 0.5 average ΔE against a spectro-profiled reference [T1]                                                                                                                                                                                       | Proprietary                                                                        | No                                                                                                   |
| Own measurements                                                        | Measure LG WOLED panels with a reference spectroradiometer and write our own CCSS                                                                                                                                                                                                     | Ours                                                                               | Yes. This is the only clean way to ship a built-in WOLED correction.                                 |

EDR layout, for reference only (from ArgyllCMS's converter [A2 `spectro/oemarch.c`]): a 600-byte header starting with `EDR DATA1` (creation time u64 at `0x18`, display description at `0x60`, technology index u32 at `0x160`, set count u32 at `0x164`, has-spectra flag u16 at `0x22E`, start/end/step nm as float64 at `0x230`/`0x238`/`0x240`), then per set a 128-byte `DISPLAY DATA` header, a 28-byte `SPECTRAL DATA` header (value count u32 at `0x10`) and float64 values in W/(nm·m²), then an optional `CORRECTION DATA` block (351 or 401 float64 values from 380 nm) that multiplies every sample. Byte order little-endian (UNCONFIRMED beyond Argyll's reading of it).

### 5.5 Recommendation

- Ship no third-party correction data.
- Implement CCSS and CCMX import (section 5.3) so users can load their own files.
- If a built-in WOLED correction is wanted, create it from our own spectroradiometer measurements of LG WOLED panels in native gamut.

## 6. macOS App Sandbox access

### 6.1 Entitlement

- Apple: `com.apple.security.device.usb` lets a sandboxed app "interact with USB devices through USB device access APIs" [P1]. The archived entitlement reference says it covers "USB devices, including HID devices such as joysticks" [P2].
- Apple DTS (Quinn, 2016): the entitlement "gates access to IOHIDLibUserClient, IOUSBDeviceUserClientV2 and IOUSBInterfaceUserClientV3". Enumeration through the I/O Registry needs no entitlement. He also warns that the sandbox profiles are "not API" [P3].
- Raw data on the research Mac (macOS 27.2, build 26B123), `/System/Library/Sandbox/Profiles/application.sb`, lines 115–118: when the app has `com.apple.security.device.hid` or `com.apple.security.device.usb`, the profile allows `iokit-open-user-client` for `IOHIDLibUserClient`. Lines 119–123 allow the two USB user clients for `com.apple.security.device.usb` only [P14]. `com.apple.security.device.hid` is not a documented entitlement, so use `com.apple.security.device.usb`.
- Both IOHIDManager and CoreHID reach the device through `IOHIDLibUserClient` [P6].

### 6.2 Input Monitoring (TCC)

- Apple DTS (2025): "We require 'Input Monitoring' for anything that the system itself 'directly' understands (keyboard, mice, etc)" [P4]. A sandboxed keyboard-reading app got "TCC deny IOHIDDeviceOpen" despite the USB entitlement [P5]. SDL treats `kIOReturnNotPermitted` from a device open as missing Input Monitoring permission [P13].
- A colorimeter should not declare keyboard or mouse usages, so no Input Monitoring prompt is expected. UNCONFIRMED, because the report descriptor is unknown. Check `PrimaryUsagePage` on hardware (section 6.6).
- If `kIOReturnNotPermitted` appears anyway, check `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` and show guidance. Never request Input Monitoring by default.
- Match only VID `0x0765` / PID `0x5020`. Do not open all HID devices.

### 6.3 Quirks and recommendations

| Topic             | Guidance                                                                                                                                                                                                                 | Source                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------- |
| Report ID         | None. Send exactly 64 bytes with "no report ID".                                                                                                                                                                         | [A2 `spectro/hidio.c`], [P10] |
| Reading replies   | Use the input-report stream or callback. Do not use get-report on input reports.                                                                                                                                         | [A2 `spectro/hidio.c`], [P6]  |
| Seize             | Argyll seizes the device. CoreHID's `seizeDevice()` gives exclusivity and throws `exclusiveAccess` if another app holds it. Whether seizing works in the sandbox is UNCONFIRMED: try it, and fall back to a shared open. | [A2 `spectro/hidio.c`], [P8]  |
| Concurrency       | One command in flight. Two apps cannot measure at the same time.                                                                                                                                                         | [A2 `spectro/i1d3.c`], [D2]   |
| Long measurements | A measurement reply can take up to about 40 s (6 s AIO, 10 s fallback, plus margin). Do not treat a quiet device as dead before that.                                                                                    | [A2 `spectro/i1d3.c`]         |
| Hot-plug          | React to `deviceRemoved` and cancel the pending command.                                                                                                                                                                 | [P12]                         |
| Kernel claim      | ArgyllCMS detaches the generic HID driver on Linux only, not on macOS. Whether macOS attaches an input-event driver depends on the usage page (UNCONFIRMED, see 6.6).                                                    | [A2 `spectro/i1d3.c`]         |

### 6.4 App Store precedent

No Mac App Store app that drives an i1d3 colorimeter was found (searched the web, forums and vendor sites). UNCONFIRMED either way. Apple's own Pro Display Calibrator supports the Display Plus HL, but it is a system app, not an App Store app [V10].

Recommendation: in the App Review notes, explain that the meter is optional hardware, include a demo video, and provide a simulated-meter mode so reviewers can use the app without the device.

### 6.5 Code signing

- App Sandbox capability plus "USB" under Hardware (sets `com.apple.security.device.usb`) [P1].
- No other entitlement is needed for HID access, based on 6.1.

### 6.6 Hardware verification checklist (run once with a real Display Plus HL)

```text
ioreg -r -c IOHIDDevice -l | grep -E '"(VendorID|ProductID|Product|Manufacturer|SerialNumber|PrimaryUsagePage|PrimaryUsage|MaxInputReportSize|MaxOutputReportSize|ReportDescriptor)"'
```

Expect VendorID 1893 (`0x0765`) and ProductID 20512 (`0x5020`). Record the usage page, report sizes (64 and 64 expected) and the report descriptor. Then log: product name, product type, firmware version, date and number, `0x10` result, hardware version string, serial prefix, lock state, and the index of the key that unlocked the unit.

## 7. Practical measurement guidance for an LG OLED TV

### 7.1 Integration time and noise

- The sensor outputs a frequency proportional to light. Frequency mode counts transitions over a fixed time, so its quantization error is about 1 count in `2 × f × T` counts. Period and AIO modes time a whole number of transitions with a 12 or 48 MHz clock, so they stay precise with few transitions, but they need at least a couple of transitions inside the time limit [A2 `spectro/i1d3.c`].
- Rough scale for the original i1d3, derived from Argyll's comment that 250 kHz is about 16,000 cd/m², so about 16 Hz per cd/m². This is an order-of-magnitude figure only. One posted Argyll debug trace shows 26 Hz in the red channel for a dim red OLED patch (38/255 red) [D8], which suggests the real scale can be a few times higher. UNCONFIRMED for all models; measure Hz ÷ Y on a 100 cd/m² white on hardware and set thresholds from that:

  | Luminance  | Sensor frequency | Cycles in 0.2 s | Time for 100 cycles         |
  | ---------- | ---------------- | --------------- | --------------------------- |
  | 1000 cd/m² | ≈ 16 kHz         | ≈ 3100          | 6 ms                        |
  | 100 cd/m²  | ≈ 1.6 kHz        | ≈ 310           | 64 ms                       |
  | 10 cd/m²   | ≈ 160 Hz         | ≈ 31            | 0.64 s                      |
  | 1 cd/m²    | ≈ 16 Hz          | ≈ 3             | 6.4 s                       |
  | 0.1 cd/m²  | ≈ 1.6 Hz         | ≈ 0.3           | 64 s (above the 6 s limit)  |
  | 0.01 cd/m² | ≈ 0.16 Hz        | ≈ 0.03          | (one cycle takes about 6 s) |

- This is consistent, in order of magnitude, with the published i1Display Pro figures: minimum integration "0.1 sec / measurement @ 100 cd/m2" and maximum "6 sec / measurement @ 0.10 cd/m2" [V8].
- Each channel sees a different share of the light. A dark saturated red patch gives the blue channel almost no signal, which is the case that triggers the Rev. B `0x83` error on OLED [A2 `log.txt`].

### 7.2 Settling time after a pattern change

- LG OLED pixels switch fast. Argyll models OLED rise and fall as 1 ms [A2 `spectro/disptechs.h`]. The delay is mostly signal-chain and TV processing latency.
- Portrait Displays recommends a "1 second delay" with a 10 % window for LG OLED monitors [T4], and "pattern stabilization" settings in its 2024 LG TV guide [T3].
- Recommendation: measure the update delay over the real pattern path at session start (section 4.6). Use `max(1.0 s, measured delay + 0.3 s)` as the default settle time for LG OLED. After settling, accept a reading only when two consecutive short readings agree (for example within 0.5 % in Y, or 0.002 cd/m² near black).

### 7.3 ABL and temporal dimming

- ABL: on an LG 42C2 in an HDR preset, 1–10 % white windows all reached 717 nits; ABL starts at about 25 % APL and falls to 152 nits at 100 % APL. It cannot be turned off [T2].
- TPC/ASBL (Temporal Peak Luminance Control): dims static content "quite quickly" on LG TVs; restored by APL changes [T2].
- Calman's 2024 LG guide uses a 10 % window for OLED in SDR, HDR and Dolby Vision, and pattern insertion at level 25 with "frequency 45, duration 5" for SDR and "frequency 5, duration 5" for HDR [T3]. The units are not stated in the source (UNCONFIRMED; probably seconds).
- DisplayCAL's administrator advises small patches, fewer patches, white-level drift compensation, pattern insertion and a patch order that maximizes lightness differences [D4].
- Recommendation: 10 % window on a black background, periodic 25 % grey insertion, and a white re-read every N patches to detect drift.

### 7.4 Repeatability

- i1Display Pro, at 100 cd/m² under X-Rite conditions: accuracy ±0.004 x,y and ±4 % luminance; short-term repeatability ±0.001 x,y and ±1 % luminance [V8].
- No published accuracy or repeatability figures for the HL models were found (UNCONFIRMED).
- Low light: repeatability gets worse as the signal falls (7.1). Average 2–3 readings below about 1 cd/m² (recommendation).

### 7.5 Near-black floor

- An LG OLED shows true black at 0 % (pixels off). The useful question is how low near-black steps can be read.
- Standard i1d3: with the 6 s limit, readings in the 0.01–0.05 cd/m² range rest on very few transitions (7.1).
- Forum data from one user (November 2023, 10-bit patterns) [D7]: the HL "stops reading around 0.004 nit vs 0.001 nit on the Calibrite Pro and Plus", and in another test "the new meter just fails to read at all, where the old meter would keep going to around 0.002". "Still returns a value" is not the same as "accurate", so treat these as upper bounds on the usable range.
- HL units: the DisplayCAL administrator also reports "worse performance in low light readings (OLED) than older models" [D1]. Expect a floor several times higher than on an i1Display Pro or Plus (exact value UNCONFIRMED).
- Recommendation: report an uncertainty with each reading (from the cycle count and repeat spread), flag readings that hit the 6 s limit or `0x83`, and do not fit calibration curves to points below the floor.

### 7.6 HDR high-luminance patches with HL models

- Rated maximum: 10,000 nits (Display Plus HL), 3000 nits (Display Pro HL) [V1] [V2]. Warn when a reading exceeds the rated maximum of the connected model.
- Bright patches give large counts, so a single 0.2 s AIO reading needs no re-measure (more than 4000 cycles) [A2 `spectro/i1d3.c`]. Keep the 250,000 Hz saturation check (4.3).
- Use the 10 % window (ABL, 7.3). Measure right after settling, because TPC dims static content. Insert mid-grey between bright patches.
- Sensor temperature drift during long bright sequences is not documented (UNCONFIRMED). Re-read a reference white periodically.

## (a) Facts the implementer can rely on

These come from primary sources (ArgyllCMS V3.5.0 source, vendor pages, Apple documentation, the local sandbox profile) or were cross-checked by two independent sources.

1. VID `0x0765`, PID `0x5020` identify the i1d3 family [A2] [U1].
2. Commands and replies are 64-byte HID reports without report IDs. Byte 0 of a command is the command code [A2].
3. The reply has status in byte 0 and an echo of the command code in byte 1, except for `0x94` (diffuser position in byte 1) and `0x10` [A2].
4. The command codes, parameter layouts and reply layouts in section 3.2 [A2], cross-checked against [O1].
5. Integers are little-endian, except the external EEPROM address, which is big-endian [A2] [O1].
6. The unlock algorithm in 3.5 and its test vectors. Success = reply byte 2 is `0x77`, followed by an unlocked lock status [A2].
7. The 11 keys in 3.6 are the complete ArgyllCMS V3.5.0 table [A2].
8. EEPROM sizes: internal 256 bytes, read in chunks of at most 60; external 8192 bytes, read in chunks of at most 59 [A2].
9. Serial number at internal `0x10` (20 chars), version string at `0x2C` (10 chars), black words at `0x04`, `0x08`, `0x0C` [A2] [O1].
10. Sensor curves: 3 × 351 float32 LE at external `0x0026`, 380–730 nm in 1 nm steps, divided by 1000; ambient transmission at `0x10BC` [A2] [O1].
11. The 12 MHz measurement clock and the conversions in 4.3 [A2].
12. The matrix math in 4.4 and 5.1, and the default MIbLSr method [A2].
13. The CCSS and CCMX keywords and field naming in 5.3 [A2].
14. Codes `0x07`, `0x13` and `0xAB` write to the device and must never be sent [O1].
15. `com.apple.security.device.usb` opens `IOHIDLibUserClient` in the App Sandbox [P3] [P14].
16. CoreHID (macOS 15+) offers set-report without a report ID, an input-report stream and `seizeDevice()` [P8] [P9] [P10] [P11].
17. Rated maxima: Display Plus HL 10,000 nits, Display Pro HL 3000 nits [V1] [V2].

## (b) UNCONFIRMED — verify on hardware

1. The Display Plus HL and Display Pro HL enumerate as `0765:5020`.
2. Which key (#1 retail or #3 generic OEM) each HL model accepts. No new key or new unlock behaviour.
3. Product name, product type, serial prefix, hardware version, firmware number, `0x10` result and AIO support on HL units.
4. HID usage page and usage; report sizes 64/64; no keyboard or mouse usage (so no Input Monitoring prompt).
5. Seize works inside the App Sandbox.
6. Black-offset units and values (Argyll's Hz interpretation versus openI1D3's counts).
7. Calibration date encoding at external `0x001E`.
8. Location of factory matrices, the lock signature and HL-specific data (18 matrices, date/time) in the external EEPROM.
9. Meaning of the AIO parameters (byte 6 = `0x07`, threshold 1000) and of the AIO flag bytes.
10. Meaning of status `0x81`, of the `0x10` nibbles and of the status command's fields.
11. Layout of `0x93` (analog sensor, possibly temperature) and `0x9B` (relock). Not to be used.
12. Whether EEPROM reads work before the unlock.
13. Whether failed unlock attempts lock the unit out.
14. The 250,000 Hz saturation limit and the Hz-per-cd/m² scale for HL sensors.
15. The low-light floor and repeatability of HL units on an LG OLED (forum figures only [D7]).
16. Whether the Display Plus HL and Display Pro HL differ in hardware.
17. The cause of the 200–300 K white-point difference between DisplayCAL and Calibrite PROFILER on a Display Pro HL.
18. The ambient-mode scale factor (lux).
19. The name of Calibrite's macOS background process that can hold the device.
20. An existing Mac App Store app that drives an i1d3.
21. Calman's pattern-insertion units.
22. The licence of DisplayCAL's bundled WOLED CCSS, and WOLED coverage in the DisplayCAL database.
23. Legal: DMCA §1201(f) applicability to the unlock, X-Rite's licensing position, and CC BY-SA 4.0 terms for the bundled CIE data. Needs counsel.

## (c) Sources

ArgyllCMS:

- [A1] ArgyllCMS source download page (V3.5.0): https://www.argyllcms.com/downloadsrc.html
- [A2] ArgyllCMS V3.5.0 source archive: https://www.argyllcms.com/Argyll_V3.5.0_src.zip. Files used: `spectro/i1d3.c`, `spectro/i1d3.h`, `spectro/insttypes.c`, `spectro/hidio.c`, `spectro/disptechs.c`, `spectro/disptechs.h`, `spectro/oemarch.c`, `xicc/xspect.c`, `xicc/ccss.c`, `xicc/ccmx.c`, `numlib/numsup.c`, `cgats/cgats.c`, `cgats/License4.txt`, `usb/55-Argyll.rules`, `ref/CRT.ccss`, `ref/oled.cmf`, `ref/License.txt`, `log.txt`, `ReadMe.txt`.
- [A3] ArgyllCMS environment variables (I1D3_ESCAPE, I1D3_DISABLE_AIO, update delay): https://www.argyllcms.com/doc/Environment.html
- [A4] ArgyllCMS oeminst: https://www.argyllcms.com/doc/oeminst.html
- [A5] ArgyllCMS contributed CCSS files: https://www.argyllcms.com/doc/ccsss.html
- [A6] ArgyllCMS supported instruments: https://www.argyllcms.com/doc/instruments.html
- [A7] ArgyllCMS dispcal (non-adaptive `-Y A` mode): https://www.argyllcms.com/doc/dispcal.html

DisplayCAL:

- [D1] DisplayCAL forum, "Display Pro HL" (Oct–Nov 2023): https://hub.displaycal.net/forums/topic/display-pro-hl/
- [D2] DisplayCAL forum, "Calibrite Display Plus HL" (Mar 2025): https://hub.displaycal.net/forums/topic/calibrite-display-plus-hl/
- [D3] DisplayCAL forum, "Official WRGB OLED correction file for the i1Display Pro" (2019–2020): https://hub.displaycal.net/forums/topic/official-wrgb-oled-correction-file-for-the-i1display-pro/
- [D4] DisplayCAL forum, "How do I compensate for OLED's auto dimming?" (2019): https://hub.displaycal.net/forums/topic/how-do-i-compensate-for-oleds-auto-dimming/
- [D5] DisplayCAL Colorimeter Corrections Database: https://colorimetercorrections.displaycal.net/
- [D6] DisplayCAL (Python 3) repository, GPL-3.0: https://github.com/eoyilmaz/displaycal-py3
- [D7] DisplayCAL forum, "is it wise to buy X-Rite i1 Display Pro Plus now in 2022", page 2 (HL vs older low-light floor, Nov 2023): https://hub.displaycal.net/forums/topic/is-it-wise-to-buy-x-rite-i1-display-pro-plus-now-in-2022/page/2/
- [D8] DisplayCAL forum, "LG 32EP950 (JOLED panel) and i1 Display Pro issues with red", page 8 (Argyll debug trace, Jan 2023): https://hub.displaycal.net/forums/topic/lg-32ep950-joled-panel-and-i1-display-pro-issues-with-red/page/8/

Vendors and specifications:

- [V1] Calibrite Display Plus HL: https://calibrite.com/us/product/display-plus-hl/
- [V2] Calibrite Display Pro HL: https://calibrite.com/us/product/display-pro-hl/
- [V3] Calibrite ColorChecker Display Plus: https://calibrite.com/us/product/colorchecker-display-plus/
- [V4] X-Rite i1D3HL OEM: https://xrite.com/categories/calibration-profiling/i1d3hl-oem
- [V5] X-Rite, OEM i1Display Pro devices: https://www.xrite.com/service-support/oem_i1display_pro_devices
- [V6] X-Rite SDK/API License: https://www.xrite.com/page/oem-licensing
- [V7] X-Rite i1Display Pro Plus: https://www.xrite.com/categories/calibration-profiling/i1display-pro-plus
- [V8] VPixx, X-Rite i1Display specifications: https://vpixx.com/products/x-rite-i1display/
- [V9] displaycalibrations.com, X-Rite i1 measurement solutions info (Rev. A/B): https://www.displaycalibrations.com/x-rite_i1_measurement_solutions_info.html
- [V10] Apple, Pro Display Calibrator full calibration (supported instruments): https://support.apple.com/guide/mac-help/full-calibration-pro-display-calibrator-mchl628f5edf/26/mac/27
- [U1] linux-usb.org USB ID list: http://www.linux-usb.org/usb.ids

Other implementations:

- [O1] openI1D3probeDriver: https://github.com/smedith/openI1D3probeDriver
- [O2] MinimalArgyllRustLib: https://github.com/Brazos-Innovation-Partners-Hub/MinimalArgyllRustLib
- [O3] calibrate-pro: https://github.com/HarperZ9/calibrate-pro
- [O4] i1d3_hook: https://github.com/ledoge/i1d3_hook
- [O5] HCFR code: https://github.com/arthur-liberman/hcfr-code
- [O6] ChromIQ: https://github.com/itsab1989/ChromIQ
- [O8] Light Illusion forum, i1D3 SDK DLL in LightSpace (2013): https://lightillusion.com/forums/msg.php?id=1256

Legal and data:

- [L1] FSF position on GPLv2 and App Store terms (vlc-devel, Nov 2010): https://mailman.videolan.org/pipermail/vlc-devel/2010-November/077031.html
- [L2] LWN, "FSF takes on Apple's App Store over GPL": https://lwn.net/Articles/391423
- [L3] 17 U.S.C. §1201 (see subsection f): https://www.law.cornell.edu/uscode/text/17/1201
- [L4] CIE 1931 2° colour-matching functions, 1 nm, 360–830 nm, CC BY-SA 4.0: https://cie.co.at/datatable/cie-1931-colour-matching-functions-2-degree-observer (metadata: https://files.cie.co.at/Publications-datasets/CIE_xyz_1931_2deg.csv_metadata.json)

Apple platform:

- [P1] `com.apple.security.device.usb`: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb
- [P2] Enabling App Sandbox (archived entitlement reference): https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html
- [P3] Apple Developer Forums 65780 (Quinn, 2016): https://developer.apple.com/forums/thread/65780
- [P4] Apple Developer Forums 804793 (Input Monitoring, CoreHID, 2025): https://developer.apple.com/forums/thread/804793
- [P5] Apple Developer Forums 724608 (TCC deny IOHIDDeviceOpen, 2023): https://developer.apple.com/forums/thread/724608
- [P6] Apple Developer Forums 773658 (CoreHID get-report through IOHIDLibUserClient, 2025): https://developer.apple.com/forums/thread/773658
- [P7] CoreHID: https://developer.apple.com/documentation/corehid
- [P8] `HIDDeviceClient.seizeDevice()`: https://developer.apple.com/documentation/corehid/hiddeviceclient/seizedevice()
- [P9] `HIDDeviceClient.dispatchSetReportRequest(type:id:data:timeout:)`: https://developer.apple.com/documentation/corehid/hiddeviceclient/dispatchsetreportrequest(type:id:data:timeout:)
- [P10] `HIDReportID`: https://developer.apple.com/documentation/corehid/hidreportid
- [P11] `HIDDeviceClient.monitorNotifications(reportIDsToMonitor:elementsToMonitor:)`: https://developer.apple.com/documentation/corehid/hiddeviceclient/monitornotifications(reportidstomonitor:elementstomonitor:)
- [P12] `HIDDeviceManager.monitorNotifications(matchingCriteria:)`: https://developer.apple.com/documentation/corehid/hiddevicemanager/monitornotifications(matchingcriteria:)
- [P13] SDL, HID enumeration and Input Monitoring: https://discourse.libsdl.org/t/sdl-dont-enumerate-hid-devices-on-macos-if-we-dont-have-input-monitoring-permissions/38822
- [P14] Local raw data: `/System/Library/Sandbox/Profiles/application.sb` on macOS 27.2 (26B123), lines 115–123. Not API [P3].

Measurement practice:

- [T1] TFTCentral, LG OLED Calman AutoCal meter-mode accuracy: https://tftcentral.co.uk/articles/lg-oled-calman-autocal-calibration-testing-meter-mode-profiles-and-accuracy
- [T2] TFTCentral, OLED dimming (APL, ABL, ASBL, TPC, GSR): https://tftcentral.co.uk/articles/oled-dimming-confusion-apl-abl-asbl-tpc-and-gsr-explained
- [T3] Portrait Displays, LG 2024 OLED and QNED AutoCal guide: https://www.portrait.com/resource-center/2024-lg-autocal-guide/
- [T4] Portrait Displays, calibrating LG EP950 / BP95E OLED monitors: https://www.portrait.com/resource-center/lg-ep950-bp95e-oled-pro-calibration/
