# Hardware commissioning checklist

Everything below is untested on real hardware. The software was verified only against simulated devices,
protocol fixtures and the tvOS Simulator. Work through the sections in order; each one gates the next.
Record results in the session notes or in a Jira issue per failure.

Legend: **[gate]** = stop if it fails · **[measure]** = needs the meter · **[inspect]** = eyes or capture card.

## 0. Before you start

- [ ] LG B4: Settings ▸ Support ▸ Software Update ▸ turn **Automatic Updates off**. webOS 26 (firmware 43.x)
      blocks third-party calibration uploads and cannot be rolled back. Note the firmware: 23.x = webOS 24,
      33.x = webOS 25 (both expected to work), 43.x = webOS 26 (settings-only workflows).
- [ ] LG B4: Settings ▸ General ▸ Devices ▸ External Devices ▸ **TV On With Mobile / Turn on via Wi-Fi** on; note
      the TV's IP (Network ▸ Wi-Fi/Wired ▸ Advanced) and MAC.
- [ ] LG B4: on the HDMI input used for calibration set **Game Optimizer** per session type and switch
      **ALLM** off for that input so the mode cannot change mid-run. HDMI Deep Colour (Ultra HD Deep Colour) on.
- [ ] Apple TV 4K (1st gen): Settings ▸ Video and Audio ▸ Format **4K SDR 60 Hz**, Match Content ▸
      **Match Dynamic Range on**, Match Frame Rate on; HDMI Output **YCbCr**; Chroma 4:2:0 (the only option at 4K60 HDR
      on this box). Same Wi-Fi/LAN as the Mac.
- [ ] Mac: Xcode ▸ Signing & Capabilities for both targets: pick your team (project.yml `DEVELOPMENT_TEAM`), keep the
      shared bundle id `com.jonathanseriesx.nitpick`. Build and install NitpickTV on the Apple TV (device must be in
      Xcode ▸ Devices; pair over the network).
- [ ] Meter: no other software holding the device (quit Calibrite PROFILER / ccProfiler; check Activity Monitor for a
      Calibrite background process).

## 1. Apple TV link **[gate]**

- [ ] Launch NitpickTV: pairing screen shows name, PIN, IP:port. Launch Nitpick (Mac) ▸ Devices ▸ Pattern source: the
      Apple TV appears via Bonjour (if not: macOS Local Network permission; try the manual host:port field).
- [ ] Enter the PIN → "Connected"; quit and relaunch the Mac app → reconnects with the stored token, no PIN.
- [ ] Send test pattern: 50 % grey 10 % window appears full screen with no overlay. Blank works.
- [ ] Standalone menu works with the Siri Remote alone (App Review needs this): focus visible, Menu returns.
- [ ] Leave a pattern on screen for 10 minutes: no screen saver, no dimming, frame persists.

## 2. Apple TV output fidelity **[inspect]** (needs an HDMI capture card or HDFury-class device; otherwise use the meter)

- [ ] SDR: request SDR mode, show grey code 502 (10-bit) and 128 (8-bit). Capture or probe reads the same code ±1
      (limited range, BT.709). If the Apple TV is set to RGB output, note range conversion and switch back to YCbCr.
- [ ] HDR10: request HDR10 → TV shows the HDR badge within ~5 s; `matchingEnabled` is true in diagnostics. If nothing
      happens, Match Dynamic Range is off (Apple TV Settings) — the app cannot force it.
- [ ] HDR10 metadata: with HDR10 1000-nit metadata selected, the TV's info panel (Settings ▸ Picture ▸ HDR info, or
      HDFury) reports MaxCLL 1000 / MaxFALL 400 and a 1000-nit mastering display. If the values are fixed regardless of
      the pattern, tvOS replaces them: note it, and calibrate with the TV's tone mapping set to the reported metadata.
- [ ] HDR10 PQ codes: 100 nits (PQ 0.5081 → code 509), 1000 nits (0.7518 → 723) measured on the TV in a bypass mode
      (or Calibration mode): luminance within what the TV's EOTF tracking shows in an independent reference (UHD test
      disc or a known-good pattern file through Infuse). Large systematic offsets mean the Apple TV re-encodes the
      video path; record them before calibrating.
- [ ] SDR → HDR10 → SDR round trip three times: no stuck mode, no black screen longer than 8 s.
- [ ] Dolby Vision: set Apple TV Format to **Dolby Vision**, Match Dynamic Range off. The TV enters DV; Nitpick's DV
      workflow displays PQ patterns through the Apple TV's HDR10→DV conversion. Confirm the TV shows "Dolby Vision",
      then compare a 100-nit grey against the HDR10 measurement: a difference > 10 % means the conversion is not
      transparent and DV results are indicative only (expected; see README).

## 3. Meter **[gate]** **[measure]**

- [ ] Plug in the Display Plus HL. `ioreg -p IOUSB -l | grep -i -A3 0765` shows vendor 0x0765; note the product id
      (expected 0x5020) and the HID usage page. If the id differs, add it to MeterKit's matching criteria.
- [ ] Nitpick ▸ Devices ▸ Meter lists the device; Connect succeeds inside the sandboxed build (no TCC denial). If it
      fails with access denied, try the un-sandboxed Debug build to separate sandbox issues from protocol issues.
- [ ] Diagnostics show product name/type, firmware, serial and which unlock key worked (retail expected). A refused
      unlock on every key = new HL key: stop, do not retry in a loop.
- [ ] Reading check against the TV at 100 nits 10 % window: 10 consecutive reads, luminance spread < 1 %, xy spread
      < 0.001. Dark patch (1 % stimulus): reads complete within 6 s and report "belowFloor" only near 0.004 nits.
- [ ] Cross-check (optional): ArgyllCMS `spotread -y o` (used as a black box) on the same patch: Y within 2 %,
      xy within 0.002. Larger differences: check the EEPROM matrix scale and black-offset units (both flagged in the
      driver as unconfirmed).
- [ ] HDR 1000-nit patch: no saturation flag; 4000-nit clip bar still reads (HL range).
- [ ] WOLED correction: import a WOLED .ccss (DisplayCAL database, own measurement, or Calibrite EDR → ccss) and confirm
      the white point shifts in the expected direction (typically ~0.002–0.004 xy).
- [ ] Unplug during a measurement → clear error, replug → reconnect works.

## 4. LG TV control **[gate]**

- [ ] Devices ▸ TV: B4 discovered via SSDP (or manual IP). Connect → TV shows the pairing prompt → Accept → registered;
      relaunch reconnects silently (client key in Keychain). The model row shows firmware token `HE_DTV_W24H…`,
      webOS release and "Calibration API: available / unavailable".
- [ ] Read picture settings: values match the TV's menus (OLED Pixel Brightness, Contrast, Brightness, Colour,
      Colour Temperature, Gamma, 2-point and 20-point white balance).
- [ ] Write one setting (Contrast 85 → 80): TV menu reflects it within 2 s and the app's read-back verification passes.
      Restore it.
- [ ] Switch input HDMI 1 → HDMI 2 → back.
- [ ] Settings snapshot taken; "Restore TV settings" writes every value back (verify three values in the TV menu).
- [ ] Calibration API probe (webOS 24/25 only): in Expert (Dark Room) on the Apple TV input with an SDR pattern,
      CAL_START succeeds (TV picture changes to Warm 50 / Wide gamut), then CAL_END. A `401` = firmware blocks it;
      a `500` = wrong signal class for the bank (check the picture mode and that the Apple TV is in SDR).
- [ ] LUT readback (GET_1D_LUT_DATA etc.) returns plausible data (the app labels it "TV readback (processed)").
      Note the 3D LUT `dataCount` (14739 = 17³ × 3 confirms the B4 table).
- [ ] Game Optimizer bank: repeat the CAL_START probe in Game Optimizer (`game`). Record whether it is accepted;
      the app assumes **no** until proven (Game sessions use controls only).
- [ ] HDR10 bank: with the Apple TV in HDR10, CAL_START for `hdr_cinema` works; Dolby Vision bank: Apple TV in DV,
      `dolby_cinema_dark` works (if not, DV config upload is unavailable on this firmware → settings-only).

## 5. First calibration runs **[measure]**

Run each in Demo mode first, then on hardware. Keep the room dark, meter centred on the 10 % window, TV warmed up 30 min,
Pixel Refresher not pending.

- [ ] **Movie SDR (Expert Dark Room, BT.1886, 100 nits)**: pre-measurement completes (~6 min); 2-point and 20-point
      white balance converge (watch for "limited by bounds"); if the calibration API is available, 1D LUT upload then
      cube; post-measurement grayscale max ΔE2000 ≤ 2, verification p95 ≤ 2.5. Compare "before" to a Calman/HCFR run if
      you have one. Power-cycle the TV: corrections persist.
- [ ] **Game SDR (Game Optimizer, 2.2, 150 nits)**: controls-only; confirm the TV's Game Optimizer menu shows the new
      white-balance values; input lag unchanged (TV info panel).
- [ ] **Movie HDR10 (HDR Cinema)**: Dynamic Tone Mapping **off** before the run; tone analysis finds the peak
      (~700–800 nits on a 10 % window) and the knee; tone-map upload accepted; PQ tracking below the knee within 5 %.
      Then set DTM to taste; HGiG for game HDR.
- [ ] **Game HDR10 (HDR Game, HGiG)**: hard clip at the peak detected; white balance improved; no uploads.
- [ ] **Dolby Vision**: source = completed Movie HDR10 session; Apple TV Format set to DV; config upload accepted;
      verification is indicative only.
- [ ] Cancel a run mid-20-point: TV settings return to the snapshot within 10 s. Pull the Apple TV's network cable
      mid-run: the run fails with a clear error and restores.
- [ ] Reboot the Mac mid-run: on relaunch the session shows "interrupted" with a Restore button; Restore works.

## 6. Distribution checks

- [ ] Archive both targets with your team; App Store Connect: one app record, platforms macOS + tvOS, same bundle id
      (universal purchase). TestFlight install on the Apple TV and the Mac.
- [ ] Sandboxed Mac build still opens the meter (entitlement `com.apple.security.device.usb`). If it does not, file a
      DTS incident before changing the distribution plan.
- [ ] App Review notes: explain the hardware, point to Demo mode, and attach a short video of a real run.
