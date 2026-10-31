# LG webOS (OLED B4, 2024): network control and calibration protocol

Research date: 2026-10-31. Target: LG OLED B4 (2024, α8 processor, shipped with webOS 24) on the newest firmware.
Audience: the engineer who writes the Swift SSAP client and a deterministic fake TV server without a TV.

Conventions in this document:

- "SSAP" means LG's second-screen WebSocket JSON protocol (`ssap://…` URIs).
- "luna" means LG's internal service bus (`luna://…` URIs). Clients cannot call it directly over SSAP.
- **UNCONFIRMED** marks a fact that no primary source confirmed for the B4. Verify it on hardware.
- Every non-obvious fact has a source link. Section (d) lists all sources.

---

## 0. Read this first: firmware status changes the whole design

| Item                                 | Status (Oct 2026)                                                                                                                                                                     | Source                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| B4 launch OS                         | webOS 24 (platform 9.x), α8 processor                                                                                                                                                 | [Notebookcheck](https://www.notebookcheck.net/New-LG-OLED-TV-line-with-webOS-24-and-Dolby-Vision-released-to-US-market.849145.0.html), [Portrait Displays 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)                                                                                                                                                                                                                                    |
| Firmware families                    | `23.xx.xx` = webOS 24 (9.x); `33.xx.xx` = webOS 25 (10.x); `43.xx.xx` = webOS 26 (11.x)                                                                                               | [bscpylgtv G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md) (v23.23.30 = webOS 9.2.4), [G5 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G5.md) (v33.21.81 = 10.2.0), [G6 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G6.md) (v43.11.77 = 11.1.0), [C2 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_C2.md) (v43.21.74 = 11.2.0) |
| B4 on webOS 25                       | Seen in the field: 33.31.25 / webOS 10.3.0; LG US lists 33.31.75 and 33.31.68 files                                                                                                   | [chronomaly-webos #2](https://github.com/AnalyticETH/chronomaly-webos/issues/2), [LG OLED48B4PUA support](https://www.lg.com/us/support/product/lg-OLED48B4PUA.AUS), [LG OLED65B4PUA support](https://www.lg.com/us/support/product/lg-OLED65B4PUA.AUS)                                                                                                                                                                                                                   |
| webOS 26 rollout                     | Started 2026-08-22 with G5 (fw 43.21.71). 2022–2024 models "later in 2026 or early 2027". One-way: no downgrade to webOS 25.                                                          | [TechTimes](https://www.techtimes.com/articles/325552/20260825/free-webos-26-update-hits-older-lg-tvs-calibration-tools-not-included.htm), [FlatpanelsHD](https://flatpanelshd.com/news.php?id=1787298592&subaction=showfull), [Pocket-lint](https://www.pocket-lint.com/lg-tvs-webos-26-update-rollout/)                                                                                                                                                                 |
| webOS 26 for B4                      | caniroot lists a `queue` variant (the codename after `ponytail`, presumably webOS 26; version not recorded) for OLED B4AUA only; other B4 SKUs show webOS 25 (`ponytail`, swMajor 33) | [caniroot models.gen.js](https://github.com/webosbrew/caniroot/blob/main/src/models.gen.js)                                                                                                                                                                                                                                                                                                                                                                               |
| webOS 26 and third-party calibration | **Blocked.** "The update removes support for ColourSpace, bscpylgtv, and the LG White Balance GUI." `CAL_START` → `401` for unsigned third-party identities.                          | [TechTimes](https://www.techtimes.com/articles/325552/20260825/free-webos-26-update-hits-older-lg-tvs-calibration-tools-not-included.htm), [Cachy's Blog](https://stadt-bremerhaven.de/lg-oled-2025-webos-26-ist-da/), [PGenerator+ #70](https://github.com/oldgithubman/PGenerator-Plus/issues/70), [PGenerator+ #71](https://github.com/oldgithubman/PGenerator-Plus/issues/71)                                                                                         |
| webOS 26 and pairing                 | The widely copied signed `com.lge.test` manifest is rejected: `403 Pairing rejected: blacklisted certificate detected`. Unsigned manifest pairs, with fewer rights.                   | [HA core #172703](https://github.com/home-assistant/core/issues/172703), [LGTVCompanion #351](https://github.com/JPersson77/LGTVCompanion/issues/351), [aiowebostv PR #719](https://github.com/home-assistant-libs/aiowebostv/pull/719)                                                                                                                                                                                                                                   |

Design consequences:

1. The client must detect the platform version (hello `deviceOSReleaseVersion`, or `getCurrentSWInformation.major_ver`) before it offers calibration.
2. On webOS 26 (release ≥ 11, firmware `43.*`), treat the calibration API as unavailable. Report it clearly; do not loop on re-pairing ([PGenerator+ #70](https://github.com/oldgithubman/PGenerator-Plus/issues/70)).
3. Tell the user to switch off automatic software updates on a B4 they want to calibrate, because webOS 26 cannot be rolled back ([TechTimes](https://www.techtimes.com/articles/325552/20260825/free-webos-26-update-hits-older-lg-tvs-calibration-tools-not-included.htm)).
4. Some EU 2024/2025 SKUs ship with calibration disabled in the factory (for example 55C41LA, 83C43LA, 55G42LW). No B4 SKU appears in the excerpts that could be read (the forum blocked direct fetching). **UNCONFIRMED** for the user's B4 ([AVS Forum capability database](https://www.avsforum.com/threads/lg-oled-eu-tvs-2024-2025-calibration-capability-database.3330101/)).
5. bscpylgtv warns that wrong calibration data "COULD brick your TV in some circumstances, requiring a mainboard replacement" ([bscpylgtv README](https://github.com/chros73/bscpylgtv/blob/master/README.md)). Validate every payload before you send it.

---

## 1. B4 identity

| Property                                                    | Value                                                                                                                                                     | Source                                                                                                                                                                                   |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SoC / processor                                             | α8 AI Processor                                                                                                                                           | [Portrait Displays 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)                                                                                          |
| Firmware model token (`getCurrentSWInformation.model_name`) | `HE_DTV_W24H_AFADATAA` (Japan: `HE_DTV_W24H_AFADJAAA`); machine `k24`                                                                                     | [caniroot models.gen.js](https://github.com/webosbrew/caniroot/blob/main/src/models.gen.js), [caniroot mappings.js](https://github.com/webosbrew/caniroot/blob/main/tools/mappings.js)   |
| Chip type (`model_name[7:11]`)                              | `W24H`                                                                                                                                                    | [bscpylgtv webos_client.py `calibration_support_info`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)                                                       |
| 3D LUT size                                                 | 17 points (`W24H` → `17pt`)                                                                                                                               | bscpylgtv (same), [PGenerator+ capability library](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/share/PGenerator/tv/lg/models/oled-2020-2026.json) (B4 → W24H, grid 17) |
| Dolby Vision config generation                              | "2019" format family                                                                                                                                      | bscpylgtv `calibration_support_info`; PGenerator+ (format_generation 2019)                                                                                                               |
| Factory DV config (B4/CS)                                   | `DMSwVersion = 4.0`, `IDK_Version = SOC_1.6.1.4`, panel `Tmax = 720`, `Tmin = 0.0001`, primaries `0.6799 0.3194 0.2626 0.6754 0.1445 0.0512 0.3127 0.329` | [bscpylgtv G4 doc, B4/CS section](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)                                                                        |
| Internal pattern generator (iTPG)                           | Calman offers the LG internal generator only for α9 and α11. **UNCONFIRMED** on α8 B4.                                                                    | [Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)                                                                                                   |
| Calman "HDR checkbox"                                       | α9/α11 only; B4 needs an external HDR pattern source                                                                                                      | [Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)                                                                                                   |

Version strings you will see:

- hello `deviceOSReleaseVersion`: `9.2.2` on webOS 24, `11.1.0` on webOS 26 ([PGenerator+ tests](https://github.com/oldgithubman/PGenerator-Plus/blob/main/t/lg_capability_runtime.t)); a B4 on firmware 33.31.25 reports webOS `10.3.0` ([chronomaly-webos #2](https://github.com/AnalyticETH/chronomaly-webos/issues/2); which field carried it is not stated). PGenerator+ selects the unsigned identity when the leading number is ≥ 11 ([pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)).
- `getCurrentSWInformation.product_name`: `webOSTV <platform major>.<minor>`, for example `webOSTV 7.0` on a 2022 set ([real capture](https://github.com/Samonac/cumulonimbus2000/blob/main/control_tv.py)). Platform 9 = webOS 24, 10 = webOS 25, 11 = webOS 26 ([omp installPlan.ts](https://github.com/spacesarmat/omp/blob/main/src/lib/installPlan.ts)).
- The UI firmware version is `major_ver + "." + minor_ver` (for example `04` + `40.91` → `04.40.91`) ([real capture](https://github.com/Samonac/cumulonimbus2000/blob/main/control_tv.py)).

---

## 2. Discovery and wake

### 2.1 SSDP

Send an M-SEARCH to `239.255.255.250:1900` over UDP. Home Assistant matches LG webOS TVs on exactly one search target ([HA webostv manifest](https://github.com/home-assistant/core/blob/dev/homeassistant/components/webostv/manifest.json)):

```
M-SEARCH * HTTP/1.1\r\n
HOST: 239.255.255.250:1900\r\n
MAN: "ssdp:discover"\r\n
MX: 3\r\n
ST: urn:lge-com:service:webos-second-screen:1\r\n
\r\n
```

Request format: [jcarbaugh discover.py gist](https://gist.github.com/jcarbaugh/e08dcfe61ece0e7eea12). Send it 2–3 times, because UDP can drop.

Captured response from a webOS TV ([openHAB community capture, 2016](https://community.openhab.org/t/connect-sdk-binding-for-lg-webos-tvs/4726?page=4)):

```
HTTP/1.1 200 OK
LOCATION: http://192.168.1.128:1702/
CACHE-CONTROL: max-age=1800
EXT:
USN: uuid:6da62662-1369-a82d-95c7-353c235ed503::urn:lge-com:service:webos-second-screen:1
ST: urn:lge-com:service:webos-second-screen:1
DATE: Sun, 17 Jan 2016 13:52:40 GMT
SERVER: WebOS/4.1.0 UPnP/1.0
```

Rules for the parser:

- Header names are case-insensitive. Take the TV address from `LOCATION`'s host, not from the UDP source.
- The `LOCATION` port changes between models and responders (observed 1702, 1873, 1340, 1400, 1505). Always fetch the advertised URL ([BrokeMyLGRemote discover.ts](https://github.com/mengkeat/BrokeMyLGRemote/blob/main/discover/discover.ts)).
- The `USN` UUID is the stable device identity. HA uses the UPnP `UDN` as the unique ID ([HA config_flow](https://github.com/home-assistant/core/blob/dev/homeassistant/components/webostv/config_flow.py)).
- LG TVs also answer `urn:schemas-upnp-org:device:MediaRenderer:1` (DLNA) and `urn:dial-multiscreen-org:service:dial:1` (DIAL). Those replies carry a URL-encoded name header, for example `DLNADeviceName.lge.com: %5bLG%5d%20webOS%20TV%20LQ63006LA` ([UMS LG-L-2022+.conf](https://github.com/UniversalMediaServer/UniversalMediaServer/blob/main/src/main/external-resources/renderers/LG-L-2022+.conf), [LGWebOSRemote scan.py](https://github.com/klattimer/LGWebOSRemote/blob/master/LGTV/scan.py)). Whether the `webos-second-screen` reply also carries this header: **UNCONFIRMED**.
- A TV in standby probably does not answer. **UNCONFIRMED.**

Device description XML at `LOCATION` (LG sample, [Connect SDK iOS test data](https://github.com/ConnectSDK/Connect-SDK-iOS-Core/blob/master/ConnectSDKTests/Discovery/Providers/sample_data/webos/ssdp_device_description_webos_minor_webos.xml)):

```xml
<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
    <friendlyName>[LG] webOS TV OLED65B4PUA</friendlyName>
    <manufacturer>LG Electronics</manufacturer>
    <manufacturerURL>http://www.lge.com</manufacturerURL>
    <modelDescription></modelDescription>
    <modelName>LG Smart TV</modelName>
    <modelURL>http://www.lge.com</modelURL>
    <modelNumber>OLED65B4PUA</modelNumber>
    <serialNumber></serialNumber>
    <UDN>uuid:6da62662-1369-a82d-95c7-353c235ed503</UDN>
    <serviceList>
      <service>
        <serviceType>urn:lge-com:service:webos-second-screen:1</serviceType>
        <serviceId>urn:lge-com:serviceId:webos-second-screen-3000-3001</serviceId>
        <SCPDURL>/WebOS_SecondScreen/6da62662-1369-a82d-95c7-353c235ed503/scpd.xml</SCPDURL>
        <controlURL>/WebOS_SecondScreen/6da62662-1369-a82d-95c7-353c235ed503/control.xml</controlURL>
        <eventSubURL>/WebOS_SecondScreen/6da62662-1369-a82d-95c7-353c235ed503/event.xml</eventSubURL>
      </service>
    </serviceList>
  </device>
</root>
```

The LG sample has `friendlyName` `MR` and `modelNumber` `42LB6300-UQ`. The `[LG] webOS TV <model>` pattern comes from [UMS renderer notes](https://github.com/UniversalMediaServer/UniversalMediaServer/blob/main/src/main/external-resources/renderers/LG-TV-2023+.conf). The B4 values above are illustrative.

### 2.2 mDNS / Bonjour

- Home Assistant has no zeroconf matcher for webOS TVs. SSDP is the only discovery path it uses ([HA generated ssdp.py](https://github.com/home-assistant/core/blob/dev/homeassistant/generated/ssdp.py)).
- LG added AirPlay 2 and HomeKit to its 2019 TVs ([Engadget](https://www.engadget.com/2019-01-07-lg-airplay-2-homekit-apple.html)). A B4 therefore probably advertises `_airplay._tcp`, `_raop._tcp` and `_hap._tcp`. **UNCONFIRMED** for the B4. The TXT records do not identify the SSAP endpoint, so use them only as a hint.
- No source shows an `_lg-smart-device._tcp` service. Do not depend on it.

### 2.3 Wake-on-LAN

MAC address: call `ssap://com.webos.service.connectionmanager/getinfo` while the TV is on. The reply has `wiredInfo.macAddress` and `wifiInfo.macAddress` ([open webOS connman adapter](https://github.com/openwebos/webos-connman-adapter/blob/master/src/connectionmanager_service.c), [lgtv2 index.js](https://github.com/hobbyquaker/lgtv2/blob/master/index.js)). lgtv2's mock also returns `p2pInfo` ([lgtv2 mock-tv.js](https://github.com/hobbyquaker/lgtv2/blob/master/test/mock-tv.js)). Store both MACs. `getCurrentSWInformation.device_id` also contains a MAC ([real capture](https://github.com/Samonac/cumulonimbus2000/blob/main/control_tv.py)).

Magic packet ([lgtv2 index.js `magicPacket`/`wake`](https://github.com/hobbyquaker/lgtv2/blob/master/index.js)):

- 102 bytes: 6 × `0xFF`, then the 6-byte MAC repeated 16 times.
- UDP, broadcast `255.255.255.255` (or the subnet broadcast), port 9, `SO_BROADCAST` on.
- Send 3 copies 100 ms apart. Send to both the wired and the Wi-Fi MAC; the TV reacts on the interface in use.
- lgtv2 measured the TV back about 2 s after the packet (webOS 6, OLED65C17LB) ([lgtv2 CHANGELOG](https://github.com/hobbyquaker/lgtv2/blob/master/CHANGELOG.md)).

TV setting that must be on:

| webOS                   | Path                                                                                                        | Source                                                                                                                         |
| ----------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 23 (and probably 24/25) | Settings → General → External Devices → TV On with Mobile → Turn on via Wi-Fi → On                          | [LG UK help library](https://www.lg.com/uk/support/product-support/troubleshoot/help-library/cs-CT00008333-20153442360449LST/) |
| 6.0 / 22                | All Settings → (General →) Devices → External Devices → TV On With Mobile → Turn on via Wi-Fi (+ Bluetooth) | same                                                                                                                           |
| 2025+ models            | Settings → Support → IP control settings → Wake on LAN                                                      | [HA webostv docs](https://www.home-assistant.io/integrations/webostv/)                                                         |

- The matching settings key is probably `network.wolwowlOnOff` (string `"true"`/`"false"`). It is readable and writable through the public SSAP settings API ([bscpylgtv G4 doc, public API lists](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)). That it is the same switch as "Turn on via Wi-Fi": **UNCONFIRMED**.
- HA recommends a wired connection and the same subnet ([HA webostv docs](https://www.home-assistant.io/integrations/webostv/)).
- `ssap://system/turnOn` no longer works on newer webOS ([bscpylgtv endpoints.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/endpoints.py)). Use WoL.

---

## 3. SSAP WebSocket control

### 3.1 Transport

| Port | Scheme            | Status                                                                                                                  | Source                                                                                                                                                                                                                        |
| ---- | ----------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 3001 | `wss://<ip>:3001` | Use this. Required since 2022/2023 firmware.                                                                            | [bscpylgtv CHANGELOG v0.4.3](https://github.com/chros73/bscpylgtv/blob/master/CHANGELOG.md) ("required by 2022 models"), [lgtv2 README](https://github.com/hobbyquaker/lgtv2/blob/master/README.md) ("firmware from 2023 on") |
| 3000 | `ws://<ip>:3000`  | Pre-2018 TVs. On new firmware it refuses the TCP connection or fails the WebSocket upgrade. Dead on a C6 with 43.21.60. | [aiowebostv webos_client.py `_create_main_ws`](https://github.com/home-assistant-libs/aiowebostv/blob/main/aiowebostv/webos_client.py), [HA #172703](https://github.com/home-assistant/core/issues/172703)                    |

TLS:

- The TV presents a static LG certificate. Leaf CN "LGE TV SSG" (serial 0x2001), issuer "LGE SSG Intermediate CA" (serial 0x1007), root "LG webOS TV Root CA". Valid 2018-03-12 to 2034-08-15. The same certificate and key ship on every TV (2018–2025 models checked) ([lgtv2 index.js](https://github.com/hobbyquaker/lgtv2/blob/master/index.js), [lgtv2 README](https://github.com/hobbyquaker/lgtv2/blob/master/README.md)).
- SHA-256 fingerprints ([lgtv2 index.js `LG_ISSUER_FINGERPRINTS`](https://github.com/hobbyquaker/lgtv2/blob/master/index.js)):
  - Intermediate: `E2:BD:64:64:D3:F5:1C:1B:95:B7:69:7D:9D:67:73:C3:3D:94:12:EB:A0:29:9C:56:8C:34:93:7D:3F:E6:8A:A0`
  - Leaf: `11:C5:B1:C5:90:77:50:AB:B9:DA:2A:66:65:CC:CE:2B:B2:88:A5:83:F4:5A:33:39:E7:1F:87:BF:2F:80:85:52`
- The hostname never matches. Every reference client disables hostname and chain checks ([bscpylgtv](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py): `check_hostname=False`, `CERT_NONE`). In Swift, accept the server trust in `URLSessionDelegate` and pin one of the fingerprints above, or pin on first use.
- Set no maximum WebSocket message size. A 33-point 3D LUT request is about 288 KB of base64; bscpylgtv uses `max_size=None` ([webos_client.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).
- Keepalive: lgtv2 pings every 10 s with a 5 s grace period ([lgtv2 index.js](https://github.com/hobbyquaker/lgtv2/blob/master/index.js)). bscpylgtv pings every 1 s with a 20 s timeout. webOS 25 sometimes needs several connect attempts; bscpylgtv retries up to 9 times, 200 ms apart, 2 s timeout each ([CHANGELOG v0.5.1](https://github.com/chros73/bscpylgtv/blob/master/CHANGELOG.md)).

### 3.2 Message framing

All frames are UTF-8 JSON text frames.

Client → TV:

```json
{
  "id": 7,
  "type": "request",
  "uri": "ssap://system/getSystemInfo",
  "payload": {}
}
```

| Field     | Values                                                                                   |
| --------- | ---------------------------------------------------------------------------------------- |
| `type`    | `hello`, `register`, `request`, `subscribe`, `unsubscribe`                               |
| `id`      | Integer or string. The TV echoes it unchanged. Use a unique value per in-flight request. |
| `uri`     | `ssap://<service>/<method>`. Not used for `hello` and `register`.                        |
| `payload` | JSON object. Send `{}` when empty.                                                       |

TV → client:

| `type`       | Meaning                                              | Shape                                                                         |
| ------------ | ---------------------------------------------------- | ----------------------------------------------------------------------------- |
| `hello`      | Reply to hello                                       | `{"type":"hello","id":"hello","payload":{…}}`                                 |
| `response`   | Success, pairing prompt notice, or subscription push | `{"type":"response","id":7,"payload":{"returnValue":true,…}}`                 |
| `registered` | Pairing accepted                                     | `{"type":"registered","id":"register_0","payload":{"client-key":"…"}}`        |
| `error`      | Transport, permission or application error           | `{"type":"error","id":7,"error":"401 insufficient permissions","payload":{}}` |

Sources: [Connect SDK socket client](https://github.com/ConnectSDK/Connect-SDK-Android-Core/blob/master/src/com/connectsdk/service/webos/WebOSTVServiceSocketClient.java), [lgtv_manager ssap_payloads.rs](https://github.com/mjoblin/lgtv_manager/blob/main/src/ssap_payloads.rs), [bscpylgtv `request`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py).

Success test (bscpylgtv): fail if `type == "error"`; else take `payload.returnValue ?? payload.subscribed`; fail if that is missing or false. A `returnValue:false` payload can carry `errorCode`, `errorText` or `errorMessage`, and sometimes `errorKey` ([lgtv2 `responseToError`](https://github.com/hobbyquaker/lgtv2/blob/master/index.js), [PGenerator+](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)). The `error` string starts with a numeric code then a space ([Connect SDK](https://github.com/ConnectSDK/Connect-SDK-Android-Core/blob/master/src/com/connectsdk/service/webos/WebOSTVServiceSocketClient.java)).

Known error strings:

| `error` string                                                                                                                     | Meaning                                                                               | Source                                                                                                                                                                          |
| ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `404 no such service or method`                                                                                                    | Unknown URI                                                                           | [bscpylgtv](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)                                                                                         |
| `401 insufficient permissions`                                                                                                     | Permission not granted to this client key                                             | [aiowebostv PR #719](https://github.com/home-assistant-libs/aiowebostv/pull/719)                                                                                                |
| `401 insufficient permissions (not registered)`                                                                                    | Key without rights (webOS 26 with legacy key)                                         | [HA #172703](https://github.com/home-assistant/core/issues/172703)                                                                                                              |
| `403 cancelled`                                                                                                                    | User declined the pairing prompt                                                      | [lgtv2 CHANGELOG 1.7.0](https://github.com/hobbyquaker/lgtv2/blob/master/CHANGELOG.md)                                                                                          |
| `403 Pairing rejected: blacklisted certificate detected`                                                                           | webOS 26 rejects the signed `com.lge.test` manifest                                   | [lgtv2 CHANGELOG 2.0.1](https://github.com/hobbyquaker/lgtv2/blob/master/CHANGELOG.md)                                                                                          |
| `500 Application error` + payload `{"returnValue":false,"errorText":"no file path from tvservice"}`                                | `getExternalPqData` without data                                                      | [aiopylgtv #44](https://github.com/bendavid/aiopylgtv/issues/44)                                                                                                                |
| `500 Application error` + payload `{"returnValue":false,"errorCode":20,"errorMessage":"Driver error while executing the command"}` | externalpq rejected by the PQ driver (wrong mode, DV not in relative mode, transient) | [PGenerator+ tests](https://github.com/oldgithubman/PGenerator-Plus/blob/main/t/lg_calibration_start_retry.t), [aiopylgtv #44](https://github.com/bendavid/aiopylgtv/issues/44) |
| `500 Application error: Some keys are not allowed for the request`                                                                 | Key not in the public `setSystemSettings` allow-list                                  | [PGenerator+ #70](https://github.com/oldgithubman/PGenerator-Plus/issues/70)                                                                                                    |
| `… category, <name> doesn't support the key(s): <key>`                                                                             | Key does not exist in that category on this firmware                                  | [pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)                                                                               |

### 3.3 hello (optional, recommended)

```json
{ "id": "hello", "type": "hello", "payload": {} }
```

Reply (webOS 3 capture, [HomeSeer LGRemote.vb](https://github.com/dcorsus/HomeSeer-MediaController/blob/master/LGRemote.vb)):

```json
{
  "type": "hello",
  "id": "hello",
  "payload": {
    "protocolVersion": 1,
    "deviceType": "tv",
    "deviceOS": "webOS",
    "deviceOSVersion": "4.1.0",
    "deviceOSReleaseVersion": "3.0.0",
    "deviceUUID": "05ee840a-cf71-15a1-12d8-11e0eb21437c",
    "pairingTypes": ["PIN", "PROMPT", "COMBINED"]
  }
}
```

- Use `deviceOSReleaseVersion` to choose the manifest (section 3.4) and to gate calibration.
- `pairingTypes` can contain `PROMPT`, `PIN`, `COMBINED`, `LGSWITCH-PIN` ([bscpylgtv constants.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/constants.py)).
- aiowebostv sends hello, then `system/getSystemInfo`, then `register`, because "newer webOS versions require system info to be retrieved before registration" ([aiowebostv `_get_pre_reg_system_info`](https://github.com/home-assistant-libs/aiowebostv/blob/main/aiowebostv/webos_client.py)). Do the same.

### 3.4 Registration and pairing

Request (bscpylgtv, [webos_client.py `registration_msg`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)):

```json
{
  "type": "register",
  "id": "register_0",
  "payload": {
    "client-key": null,
    "forcePairing": false,
    "manifest": { "…": "see below" },
    "pairingType": "PROMPT"
  }
}
```

`client-key` is `null` (or absent) on first pairing, and the stored key afterwards.

**Manifest A: legacy signed (webOS ≤ 25; needed for calibration and settings writes).** Verbatim from [bscpylgtv manifest.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/manifest.py) (MIT). aiopylgtv has the same manifest without `deviceName` and `READ_STORAGE_DEVICE_LIST` ([aiopylgtv handshake.py](https://github.com/bendavid/aiopylgtv/blob/master/aiopylgtv/handshake.py)):

```json
{
  "appVersion": "1.1",
  "manifestVersion": 1,
  "deviceName": "bscpylgtv",
  "permissions": [
    "LAUNCH",
    "LAUNCH_WEBAPP",
    "APP_TO_APP",
    "CLOSE",
    "TEST_OPEN",
    "TEST_PROTECTED",
    "CONTROL_AUDIO",
    "CONTROL_DISPLAY",
    "CONTROL_INPUT_JOYSTICK",
    "CONTROL_INPUT_MEDIA_RECORDING",
    "CONTROL_INPUT_MEDIA_PLAYBACK",
    "CONTROL_INPUT_TV",
    "CONTROL_POWER",
    "CONTROL_TV_SCREEN",
    "READ_APP_STATUS",
    "READ_CURRENT_CHANNEL",
    "READ_INPUT_DEVICE_LIST",
    "READ_NETWORK_STATE",
    "READ_RUNNING_APPS",
    "READ_TV_CHANNEL_LIST",
    "WRITE_NOTIFICATION_TOAST",
    "READ_POWER_STATE",
    "READ_COUNTRY_INFO",
    "CONTROL_INPUT_TEXT",
    "CONTROL_MOUSE_AND_KEYBOARD",
    "READ_INSTALLED_APPS",
    "READ_SETTINGS",
    "READ_STORAGE_DEVICE_LIST"
  ],
  "signatures": [
    {
      "signature": "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw==",
      "signatureVersion": 1
    }
  ],
  "signed": {
    "appId": "com.lge.test",
    "created": "20140509",
    "localizedAppNames": {
      "": "LG Remote App",
      "ko-KR": "리모컨 앱",
      "zxx-XX": "ЛГ Rэмotэ AПП"
    },
    "localizedVendorNames": { "": "LG Electronics" },
    "permissions": [
      "TEST_SECURE",
      "CONTROL_INPUT_TEXT",
      "CONTROL_MOUSE_AND_KEYBOARD",
      "READ_INSTALLED_APPS",
      "READ_LGE_SDX",
      "READ_NOTIFICATIONS",
      "SEARCH",
      "WRITE_SETTINGS",
      "WRITE_NOTIFICATION_ALERT",
      "CONTROL_POWER",
      "READ_CURRENT_CHANNEL",
      "READ_RUNNING_APPS",
      "READ_UPDATE_INFO",
      "UPDATE_FROM_REMOTE_APP",
      "READ_LGE_TV_INPUT_EVENTS",
      "READ_TV_CURRENT_TIME"
    ],
    "serial": "2f930e2d2cfe083771f68e4fe7bb07",
    "vendorId": "com.lge"
  }
}
```

The signature string is one line in the wire JSON. Copy it byte-exact from the source file; this document joins bscpylgtv's split string literal.

Why the signed manifest matters: the outer `permissions` list is what the user accepts on the prompt. The `signed.permissions` list (for example `WRITE_SETTINGS`, `WRITE_NOTIFICATION_ALERT`, `READ_UPDATE_INFO`, `TEST_SECURE`) is granted by signature check ([LGTVCompanion #351](https://github.com/JPersson77/LGTVCompanion/issues/351), [aiowebostv PR #719](https://github.com/home-assistant-libs/aiowebostv/pull/719)). PGenerator+: "Older LG generations need the certified registration manifest for calibration and DDC permissions" ([pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)). Which single permission gates `externalpq`: **UNCONFIRMED**.

**Manifest B: generic unsigned (webOS 26 fallback).** From [aiowebostv handshake.py](https://github.com/home-assistant-libs/aiowebostv/blob/main/aiowebostv/handshake.py) (Apache-2.0):

```json
{
  "appVersion": "1.1",
  "manifestVersion": 1,
  "permissions": [
    "APP_TO_APP",
    "CLOSE",
    "CONTROL_AUDIO",
    "CONTROL_DISPLAY",
    "CONTROL_INPUT_JOYSTICK",
    "CONTROL_INPUT_MEDIA_PLAYBACK",
    "CONTROL_INPUT_MEDIA_RECORDING",
    "CONTROL_INPUT_TEXT",
    "CONTROL_INPUT_TV",
    "CONTROL_MOUSE_AND_KEYBOARD",
    "CONTROL_POWER",
    "CONTROL_TV_SCREEN",
    "LAUNCH",
    "LAUNCH_WEBAPP",
    "READ_APP_STATUS",
    "READ_COUNTRY_INFO",
    "READ_CURRENT_CHANNEL",
    "READ_INPUT_DEVICE_LIST",
    "READ_INSTALLED_APPS",
    "READ_LGE_SDX",
    "READ_LGE_TV_INPUT_EVENTS",
    "READ_NETWORK_STATE",
    "READ_NOTIFICATIONS",
    "READ_POWER_STATE",
    "READ_RUNNING_APPS",
    "READ_SETTINGS",
    "READ_TV_CHANNEL_LIST",
    "READ_TV_CURRENT_TIME",
    "READ_UPDATE_INFO",
    "SEARCH",
    "TEST_OPEN",
    "TEST_PROTECTED",
    "TEST_SECURE",
    "UPDATE_FROM_REMOTE_APP",
    "WRITE_NOTIFICATION_ALERT",
    "WRITE_NOTIFICATION_TOAST",
    "WRITE_SETTINGS"
  ]
}
```

On webOS 26 this pairs, but `WRITE_SETTINGS` and `READ_UPDATE_INFO` stayed denied on an OLED77C67LA even after re-pairing ([aiowebostv PR #719 comments](https://github.com/home-assistant-libs/aiowebostv/pull/719)). LGTV Companion reports the opposite on other firmware ([LGTVCompanion #351](https://github.com/JPersson77/LGTVCompanion/issues/351)). LG's own Connect SDK uses only `manifestVersion` + `permissions` ([Connect SDK `setDefaultManifest`](https://github.com/ConnectSDK/Connect-SDK-Android-Core/blob/master/src/com/connectsdk/service/webos/WebOSTVServiceSocketClient.java)).

Recommended manifest strategy (PGenerator+ and lgtv2 do this):

1. If hello `deviceOSReleaseVersion` ≥ 11 → send manifest B.
2. Else send manifest A. If the reply is `403 Pairing rejected: blacklisted certificate detected` → open a fresh socket and register again with manifest B ([lgtv2 index.js `register`](https://github.com/hobbyquaker/lgtv2/blob/master/index.js), [pgenerator-lg `lg_register_session_with_compatibility`](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)).
3. After registration, probe one cheap call. A key without rights answers `401 … (not registered)` to everything ([PGenerator+ #68](https://github.com/oldgithubman/PGenerator-Plus/issues/68)).

PROMPT flow ([bscpylgtv `connect_handler`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py), [lgtv2 mock-tv.js](https://github.com/hobbyquaker/lgtv2/blob/master/test/mock-tv.js)):

1. Client → `register` with `client-key: null`.
2. TV → `{"type":"response","id":"register_0","payload":{"pairingType":"PROMPT","returnValue":true}}`. The TV shows a dialog.
3. User accepts → TV → `{"type":"registered","id":"register_0","payload":{"client-key":"<32 hex chars>"}}`. User declines → `{"type":"error","id":"register_0","error":"403 cancelled","payload":{}}`.
4. With a valid stored key, the TV answers `registered` at once with the same key (no prompt).

How long the TV waits before it drops an unanswered prompt: **UNCONFIRMED**. Keep the socket open and wait at least 60 s.

PIN flow: register with `"pairingType":"PIN"`. The TV answers `pairingType:"PIN"` and shows a code. Then send ([Connect SDK `sendPairingKey`](https://github.com/ConnectSDK/Connect-SDK-Android-Core/blob/master/src/com/connectsdk/service/webos/WebOSTVServiceSocketClient.java), [bscpylgtv](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)):

```json
{
  "type": "request",
  "id": "register_1",
  "uri": "ssap://pairing/setPin",
  "payload": { "pin": "12345678" }
}
```

The reply is `registered`. Calman pairs with an 8-digit passcode shown on the TV ([Portrait guide](https://www.portrait.com/resource-center/calibrating-lg-tvs-with-calman/)).

Client-key persistence:

- One key per TV. Key it by the SSDP UUID or hello `deviceUUID`, not by IP. Connect SDK drops the stored key when `deviceUUID` changes ([Connect SDK](https://github.com/ConnectSDK/Connect-SDK-Android-Core/blob/master/src/com/connectsdk/service/webos/WebOSTVServiceSocketClient.java)).
- Store the key before you send the first command; lgtv2 2.1.0 fixed a lost-key bug in short-lived scripts ([lgtv2 CHANGELOG](https://github.com/hobbyquaker/lgtv2/blob/master/CHANGELOG.md)).
- Store which manifest produced the key. A key from manifest A has different rights from a key from manifest B.
- The paired app appears in the TV's connected-apps list ("LG Connect Apps") ([PGenerator+ #68](https://github.com/oldgithubman/PGenerator-Plus/issues/68)).

### 3.5 Subscriptions

- Send `"type":"subscribe"` with a normal `uri`/`payload`. The first reply is a `response` with `payload.subscribed: true`. Some firmware omits `subscribed` ([lgtv2 index.js `handleMessage`](https://github.com/hobbyquaker/lgtv2/blob/master/index.js)).
- Later pushes reuse the same `id` with `"type":"response"`.
- Cancel with `{"id": <same id>, "type": "unsubscribe"}` ([lgtv2](https://github.com/hobbyquaker/lgtv2/blob/master/index.js)).
- Useful subscriptions: `com.webos.service.tvpower/power/getPowerState`, `com.webos.applicationManager/getForegroundAppInfo`, `settings/getSystemSettings` (picture keys), `audio/getVolume`, `tv/getExternalInputList` ([bscpylgtv](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).

### 3.6 URI catalogue

All URIs are `ssap://` + the path below. Endpoint list: [bscpylgtv endpoints.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/endpoints.py).

| Path                                                             | Payload                                                                                              | Success payload (fields)                                                                                                                                                             | Notes / source                                                                                                                                                                                                                                                                                                                                                                                                       |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `system/getSystemInfo`                                           | `{}` (ColorControl passes `{"keys":[…]}`)                                                            | `features{3d,dvr}`, `receiverType`, `modelName`, `serialNumber` (not always), `programMode`                                                                                          | [lgtv_manager](https://github.com/mjoblin/lgtv_manager/blob/main/src/ssap_payloads.rs). aiowebostv and PGenerator+ send it before `register` ([aiowebostv](https://github.com/home-assistant-libs/aiowebostv/blob/main/aiowebostv/webos_client.py), [pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)); whether it answers before registration on a B4: UNCONFIRMED. |
| `com.webos.service.update/getCurrentSWInformation`               | `{}`                                                                                                 | `product_name`, `model_name`, `sw_type`, `major_ver`, `minor_ver`, `country`, `country_group`, `device_id`, `auth_flag`, `ignore_disable`, `eco_info`, `config_key`, `language_code` | [lgtv_manager](https://github.com/mjoblin/lgtv_manager/blob/main/src/ssap_payloads.rs), [real capture](https://github.com/Samonac/cumulonimbus2000/blob/main/control_tv.py). Needs `READ_UPDATE_INFO` (signed); `401` on webOS 26 with manifest B ([aiowebostv PR #719](https://github.com/home-assistant-libs/aiowebostv/pull/719)).                                                                                |
| `system/turnOff`                                                 | `{}`                                                                                                 | `returnValue`                                                                                                                                                                        | The reply can be lost while the TV shuts down; bscpylgtv does not wait for it ([webos_client.py `power_off`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).                                                                                                                                                                                                                           |
| `com.webos.service.tvpower/power/getPowerState`                  | `{}`                                                                                                 | `state`, `processing`                                                                                                                                                                | `state` ∈ `Active`, `Active Standby`, `Suspend`, `Screen Off`, `Screen Saver`, `Power Off` ([lgtv2 `POWER_STATES`](https://github.com/hobbyquaker/lgtv2/blob/master/index.js)).                                                                                                                                                                                                                                      |
| `com.webos.service.tvpower/power/turnOffScreen` / `turnOnScreen` | `{"standbyMode":"active"}`                                                                           | `returnValue`                                                                                                                                                                        | Panel off, set stays on ([bscpylgtv](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).                                                                                                                                                                                                                                                                                                   |
| `com.webos.service.connectionmanager/getinfo`                    | `{}`                                                                                                 | `wiredInfo.macAddress`, `wifiInfo.macAddress`, (`p2pInfo`)                                                                                                                           | Section 2.3.                                                                                                                                                                                                                                                                                                                                                                                                         |
| `tv/getExternalInputList`                                        | `{}`                                                                                                 | `devices[]`: `id` (`HDMI_1`…), `label`, `port`, `connected`, `appId` (`com.webos.app.hdmi1`…), `icon`, `modified`, `lastUniqueId`, `hdmiPlugIn`, `subList`, `subCount`, `favorite`   | [lgtv_manager](https://github.com/mjoblin/lgtv_manager/blob/main/src/ssap_payloads.rs), [real dump](https://github.com/MatKlucznyk/LgWebOs/blob/master/WebSocket%20Requests/commands)                                                                                                                                                                                                                                |
| `tv/switchInput`                                                 | `{"inputId":"HDMI_2"}`                                                                               | `returnValue`                                                                                                                                                                        | [bscpylgtv `set_input`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)                                                                                                                                                                                                                                                                                                                  |
| `tv/getCurrentChannel`                                           | `{}`                                                                                                 | channel object                                                                                                                                                                       | Only succeeds while Live TV (`com.webos.app.livetv`) runs ([bscpylgtv `set_current_app_state`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)). Not useful for HDMI calibration.                                                                                                                                                                                                        |
| `com.webos.applicationManager/getForegroundAppInfo`              | `{}`                                                                                                 | `appId`, `windowId`, `processId`                                                                                                                                                     | On HDMI `appId` = `com.webos.app.hdmiN`. Empty `appId` while powering down ([Hubitat driver](https://github.com/syepes/Hubitat/blob/master/Drivers/LG/LG%20WebOS%20TV.groovy)).                                                                                                                                                                                                                                      |
| `system.launcher/launch`                                         | `{"id":"<appId>"}` (+ `params`, `contentId`)                                                         | `returnValue` (+ `id`: UNCONFIRMED)                                                                                                                                                  | Launching `com.webos.app.hdmi2` also switches input. `com.palm.app.settings` with `{"target":"PictureMode"}` opens picture settings ([bscpylgtv README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).                                                                                                                                                                                                |
| `system.launcher/close`                                          | `{"id":"<appId>"}`                                                                                   | `returnValue`                                                                                                                                                                        |                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `com.webos.applicationManager/listApps`                          | `{}`                                                                                                 | `apps[]`                                                                                                                                                                             | Includes hidden apps. `listLaunchPoints` → `launchPoints[]`.                                                                                                                                                                                                                                                                                                                                                         |
| `audio/getVolume`                                                | `{}`                                                                                                 | old: `volume`, `muted`; new: `volumeStatus{volume, muteStatus, soundOutput, maxVolume, …}`, `callerId`                                                                               | Normalize both ([lgtv2](https://github.com/hobbyquaker/lgtv2/blob/master/index.js), [lgtv_manager](https://github.com/mjoblin/lgtv_manager/blob/main/src/ssap_payloads.rs)).                                                                                                                                                                                                                                         |
| `system.notifications/createToast`                               | `{"message":"…"}` (+ `iconData` base64, `iconExtension`)                                             | `returnValue` (+ `toastId`: UNCONFIRMED)                                                                                                                                             | Newer firmware may drop a toast that has an icon ([HA docs](https://www.home-assistant.io/integrations/webostv/)).                                                                                                                                                                                                                                                                                                   |
| `system.notifications/createAlert`                               | section 3.7                                                                                          | `returnValue`, `alertId`                                                                                                                                                             | Needs `WRITE_NOTIFICATION_ALERT` (signed).                                                                                                                                                                                                                                                                                                                                                                           |
| `system.notifications/closeAlert`                                | `{"alertId":"…"}`                                                                                    | `returnValue`                                                                                                                                                                        |                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `settings/getSystemSettings`                                     | `{"category":"picture","keys":["backlight",…]}`                                                      | `category`, `settings{…}`, `returnValue`, `subscribed`                                                                                                                               | Section 4. Response shape from an observed-TV mock ([LG_Buddy test server](https://github.com/Staphylococcus/LG_Buddy/blob/main/crates/lg-buddy/src/web_os/test_support/test_server.rs)).                                                                                                                                                                                                                            |
| `settings/setSystemSettings`                                     | `{"category":"picture","settings":{…}}` (+ `"current_app": true` for `truMotionMode`, `aspectRatio`) | `{"method":"setSystemSettings","returnValue":true}`                                                                                                                                  | Public allow-list only (section 4.1).                                                                                                                                                                                                                                                                                                                                                                                |
| `externalpq/setExternalPqData`                                   | section 5                                                                                            | `returnValue`                                                                                                                                                                        | Calibration.                                                                                                                                                                                                                                                                                                                                                                                                         |
| `externalpq/getExternalPqData`                                   | `{"command":"GET_…"}`                                                                                | `data`, `dataCount`, `dataType`, `returnValue`                                                                                                                                       | Section 5.7.                                                                                                                                                                                                                                                                                                                                                                                                         |
| `com.webos.service.networkinput/getPointerInputSocket`           | `{}`                                                                                                 | `socketPath` (a `wss://…` URL)                                                                                                                                                       | Second socket for buttons: text frames `type:button\nname:INFO\n\n` ([bscpylgtv `button`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).                                                                                                                                                                                                                                              |
| `api/getServiceList`                                             | `{}`                                                                                                 | `services[]`                                                                                                                                                                         | Lists SSAP services.                                                                                                                                                                                                                                                                                                                                                                                                 |

### 3.7 The luna bridge through `createAlert`

SSAP cannot call `luna://` URIs. The workaround makes the TV call a luna URI as the click/close/fail action of a notification alert, then closes the alert at once. The luna call's return value is not visible to the client ([bscpylgtv `luna_request`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py), [aiopylgtv](https://github.com/bendavid/aiopylgtv/blob/master/aiopylgtv/webos_client.py)).

Step 1: create the alert. Exact payload for a picture write:

```json
{
  "id": 21,
  "type": "request",
  "uri": "ssap://system.notifications/createAlert",
  "payload": {
    "message": " ",
    "buttons": [
      {
        "label": "",
        "onClick": "luna://com.webos.settingsservice/setSystemSettings",
        "params": {
          "category": "picture",
          "settings": { "backlight": "40", "contrast": "85" }
        }
      }
    ],
    "onclose": {
      "uri": "luna://com.webos.settingsservice/setSystemSettings",
      "params": {
        "category": "picture",
        "settings": { "backlight": "40", "contrast": "85" }
      }
    },
    "onfail": {
      "uri": "luna://com.webos.settingsservice/setSystemSettings",
      "params": {
        "category": "picture",
        "settings": { "backlight": "40", "contrast": "85" }
      }
    }
  }
}
```

Reply: `{"type":"response","id":21,"payload":{"returnValue":true,"alertId":"com.webos.service.apiadapter.pub-1786895965205"}}` ([LG_Buddy observed-TV mock](https://github.com/Staphylococcus/LG_Buddy/blob/main/crates/lg-buddy/src/web_os/test_support/test_server.rs)).

Step 2: close the alert. Closing fires `onclose`, which runs the luna call.

```json
{
  "id": 22,
  "type": "request",
  "uri": "ssap://system.notifications/closeAlert",
  "payload": { "alertId": "<id>" }
}
```

- bscpylgtv and ColorControl send the `alertId` unchanged ([bscpylgtv](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py), [ColorControl LgTvApi.cs](https://github.com/Maassoft/ColorControl/blob/master/ColorControl/lgtv/LgTvApi.cs)).
- LG_Buddy, modeled on a webOS 24 (9.2.2-61) TV, rewrites `com.webos.service.apiadapter.pub-<n>` to `com.webos.service.apiadapter-<n>` before `closeAlert` ([LG_Buddy picture.rs](https://github.com/Staphylococcus/LG_Buddy/blob/main/crates/lg-buddy/src/web_os/picture.rs)). Which form the B4 requires: **UNCONFIRMED**. Send the rewritten id first; on error, send the raw id. The fake server should accept both.
- Verify every luna write by reading the key back with `settings/getSystemSettings` after about 1 s ([LG_Buddy `BACKLIGHT_WRITE_READBACK_DELAY`](https://github.com/Staphylococcus/LG_Buddy/blob/main/crates/lg-buddy/src/web_os/picture.rs)).
- A blank alert may flash on screen. Do not measure during a luna write.
- Required permissions: `WRITE_NOTIFICATION_ALERT` (and `WRITE_SETTINGS` in LG_Buddy's model) ([LG_Buddy test server](https://github.com/Staphylococcus/LG_Buddy/blob/main/crates/lg-buddy/src/web_os/test_support/test_server.rs)).

Useful luna targets ([bscpylgtv endpoints.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/endpoints.py)):

| luna URI                                                                        | Params                                                         | Use                                                          |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------ |
| `com.webos.settingsservice/setSystemSettings`                                   | `{"category": …, "settings": {…}}` (+ `current_app`)           | Any settings key, not only the public allow-list             |
| `com.webos.service.eim/setDeviceInfo`                                           | `{"id":"HDMI_2","icon":"pc.png","label":"PC"}`                 | PC mode on/off per input                                     |
| `com.webos.service.oledepl/setTemporalPeakControl` / `setGlobalStressReduction` | `{"enable": false}`                                            | Service-menu TPC/GSR (dimming algorithms), 2020+             |
| `com.webos.service.pqcontroller/setWhiteBalance`                                | `{"colorTemp":"warm","gain":[r,g,b],"offset":[r,g,b]}` (0–255) | Service-menu white balance. Do not use in a normal workflow. |
| `com.webos.service.pqcontroller/setProperties`                                  | `{"dolbyCfgAlertReturn":"Update"}` or `"Restore"`              | Accept the USB Dolby Vision config popup                     |
| `com.webos.service.config/setConfigs`                                           | `{"configs":{…}}`                                              | Disabled on newer webOS                                      |

### 3.8 Permission matrix (what each manifest gets)

| Capability                   | webOS 24/25 + manifest A | webOS 26 + manifest B                        | Source                                                                                                                                                         |
| ---------------------------- | ------------------------ | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pairing                      | yes                      | yes (manifest A → `403 … blacklisted`)       | [HA #172703](https://github.com/home-assistant/core/issues/172703)                                                                                             |
| Read picture settings        | yes                      | yes ("20 picture keys readable")             | [PGenerator+ #70](https://github.com/oldgithubman/PGenerator-Plus/issues/70)                                                                                   |
| `settings/setSystemSettings` | yes (allow-list)         | `401` or `500 … Some keys are not allowed`   | [aiowebostv PR #719](https://github.com/home-assistant-libs/aiowebostv/pull/719), [PGenerator+ #70](https://github.com/oldgithubman/PGenerator-Plus/issues/70) |
| `getCurrentSWInformation`    | yes                      | `401 insufficient permissions`               | [aiowebostv PR #719](https://github.com/home-assistant-libs/aiowebostv/pull/719)                                                                               |
| Pointer input socket         | yes                      | varies by firmware                           | [Orishas webos26 fix](https://github.com/Orishas/webostv-webos26-fix)                                                                                          |
| `externalpq` (CAL_START)     | yes                      | `401 insufficient permissions` (fw 43.21.71) | [PGenerator+ #71](https://github.com/oldgithubman/PGenerator-Plus/issues/71)                                                                                   |
| luna bridge (`createAlert`)  | yes                      | **UNCONFIRMED**                              | —                                                                                                                                                              |

---

## 4. Picture settings (`com.webos.settingsservice`)

### 4.1 Read and write APIs

Read (public SSAP):

```json
{
  "id": 30,
  "type": "request",
  "uri": "ssap://settings/getSystemSettings",
  "payload": {
    "category": "picture",
    "keys": ["pictureMode", "backlight", "contrast"]
  }
}
```

Reply ([LG_Buddy observed-TV mock](https://github.com/Staphylococcus/LG_Buddy/blob/main/crates/lg-buddy/src/web_os/test_support/test_server.rs)):

```json
{
  "type": "response",
  "id": 30,
  "payload": {
    "category": "picture",
    "returnValue": true,
    "settings": {
      "pictureMode": "expert2",
      "backlight": "34",
      "contrast": "85"
    },
    "subscribed": false
  }
}
```

- `keys` is required. Without a `dimension`, reads target the current context (current input, current signal class) ([felixcool200 settings research](https://github.com/felixcool200/webOS-apps/blob/main/docs/settings-plan.md)).
- If one key is unknown, the reply can be `returnValue:false` with the known keys in `settings` and the rest in `errorKey` (seen through luna) ([felixcool200](https://github.com/felixcool200/webOS-apps/blob/main/docs/settings-plan.md)). PGenerator+ drops the refused keys and retries the rest ([pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)).
- Public read allow-list for `picture` on webOS 24 (G4 doc): `brightness, backlight, contrast, color, energySaving, pictureMode, dynamicContrast, peakBrightness, gamma, blackLevel, motionEyeCare, colorGamut, hdrDynamicToneMapping, realCinema, truMotionMode, tint, adjustingLuminance, colorTemperature, whiteBalancePoint, superResolution, sharpness, noiseReduction, mpegNoiseReduction, smoothGradation, dynamicColor, whiteBalanceMethod, whiteBalanceIre10pt, whiteBalanceIre, whiteBalanceRedOffset, whiteBalanceRedGain, whiteBalanceRed10pt, whiteBalanceRed, adjustingLuminance10pt, whiteBalanceGreenOffset, whiteBalanceGreenGain, whiteBalanceGreen10pt, whiteBalanceGreen, whiteBalanceBlueOffset, whiteBalanceBlueGain, whiteBalanceBlue10pt, whiteBalanceBlue, colorManagementColorSystem, colorManagementSaturation{Red,Green,Blue,Cyan,Magenta,Yellow}, colorManagementHue{…}, colorManagementLuminance{…}, whiteBalanceLuminance` ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)).
- Other public read categories on webOS 24: `other` (`simplinkEnable, ueiEnable, gameWallpaper, uhdDeepColorHDMI1..4`), `network` (`deviceName, wolwowlOnOff, bleAdvertisingOnOff`), `option`, `sound`, `general`, `time`, `twinTv`, `lock`, `aspectRatio`, `support`, `""` (same doc).

Write (public SSAP), same allow-list as read for `picture` (webOS 24 G4 doc):

```json
{
  "id": 31,
  "type": "request",
  "uri": "ssap://settings/setSystemSettings",
  "payload": {
    "category": "picture",
    "settings": { "backlight": 34, "contrast": 85 }
  }
}
```

- Public `pictureMode` writes need webOS 9 (2024) or newer: `{"category":"picture","settings":{"pictureMode":"expert2"}}` ([bscpylgtv `set_system_picture_mode`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).
- `truMotionMode` needs `"current_app": true` in the payload ([bscpylgtv `set_system_settings`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).
- Keys outside the allow-list (for example `peakBrightness` is in it, `DtmMastering1k` is not) need the luna bridge (section 3.7).

Write via luna (any key):

- No dimension: `{"category":"picture","settings":{…}}` writes the current context ([bscpylgtv `set_settings`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).
- Dimension encoded in the category string (bscpylgtv `set_picture_mode` / `set_picture_settings`):
  - Picture mode of an input and signal class: `"category": "picture$<input>.x.<3d>.<dynamicRange>"`, settings `{"pictureMode": "<mode>"}`. Example: `picture$hdmi2.x.2d.sdr`.
  - Other picture keys of an input and mode: `"category": "picture$<input>.<pictureMode>.<3d>.x"`. Example: `picture$hdmi2.expert2.2d.x`.
  - `x` marks a dimension the key does not use. `category` can also be `aiPicture`.
- Dimension object (luna `getSystemSettings`/`setSystemSettings` with `"dimension": {"input":"hdmi3","pictureMode":"eco"}`) worked on a rooted TV ([felixcool200](https://github.com/felixcool200/webOS-apps/blob/main/docs/settings-plan.md)). Through the createAlert bridge: **UNCONFIRMED**.

### 4.2 The dimension model (how settings are stored)

From settingsservice reads on a TV ([felixcool200](https://github.com/felixcool200/webOS-apps/blob/main/docs/settings-plan.md); [webOS OSE settingsservice source](https://github.com/webosose/settingsservice/blob/master/Src/PrefsKeyDescMap.cpp)):

| Key group                                                   | Dimension                                 |
| ----------------------------------------------------------- | ----------------------------------------- |
| Most `picture` keys (backlight, contrast, white balance, …) | `[input, pictureMode]` (plus `_3dStatus`) |
| `pictureMode`                                               | `[input, dynamicRange]`                   |
| `aspectRatio`                                               | `[input]`                                 |
| `justScan`                                                  | `[input, resolution]`                     |
| `pictureSettingModified`                                    | `[input]`                                 |
| Energy saving, FILMMAKER MODE auto start                    | none (global)                             |

- A picture write without a dimension changes the current input + current mode only. Each input therefore keeps its own copy of backlight/contrast/etc. per picture mode.
- Input names in dimensions are lower case: `hdmi1`…`hdmi4`, PC-mode inputs `hdmi1_pc`…`hdmi4_pc`, apps `default`. `HDMI_2` fails ("There is no matched result from DB") ([felixcool200](https://github.com/felixcool200/webOS-apps/blob/main/docs/settings-plan.md)).
- Full input list on webOS 24: `atv, av1, av2, browser, camera, comp1, comp2, comp3, default, dp1, dp2, dtv, gallery, hdmi1, hdmi1_pc, hdmi2, hdmi2_pc, hdmi3, hdmi3_pc, hdmi4, hdmi4_pc, ip, movie, photo, pictest, rgb, scart, smhl, usbc1, usbc2` ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)).
- `dynamicRange` values: `sdr, sdrALLM, hdr, hdrALLM, technicolorHdr, technicolorHdrALLM, dolbyHdr, dolbyHdrALLM`. HLG shares the `hdr` group with HDR10 (same doc; [bscpylgtv README](https://github.com/chros73/bscpylgtv/blob/master/README.md): "HDR10(+HLG)").
- `_3dStatus`: `2d` or `3d`.
- The luna `getSystemSettings` reply carries the current context in `dimension`, for example `{"input":"default","_3dStatus":"2d","dynamicRange":"dolbyHdr"}` ([plx-native dolby-vision.md](https://github.com/GLinnik21/plx-native/blob/main/docs/dolby-vision.md)). Whether the SSAP reply carries `dimension`: **UNCONFIRMED** (the observed-TV mock does not).
- ColorControl reads the context over SSAP with `{"category":"dimensionInfo","keys":["input","_3dStatus","colorSystem","dynamicRange","gameInput"]}` ([ColorControl LgTvApi.cs `GetSystemSettings2`](https://github.com/Maassoft/ColorControl/blob/master/ColorControl/lgtv/LgTvApi.cs)). Whether this works on a B4: **UNCONFIRMED**.
- Reliable fallback: input = `getForegroundAppInfo.appId` (`com.webos.app.hdmiN` → `hdmiN`); signal class = prefix of the current `pictureMode` (`hdr*` → HDR10/HLG, `dolbyHdr*` → Dolby Vision, else SDR).

### 4.3 Picture modes and calibration bank names

Settings values (webOS 24 enum): `personalized, hdrPersonalized, dolbyHdrPersonalized, vivid, hdrVivid, normal, eco, cinema, hdrStandard, hdrEco, hdrCinemaBright, hdrCinema, sports, game, photo, hdrGame, filmMaker, hdrFilmMaker, dolbyHdrVivid, dolbyHdrStandard, dolbyHdrCinemaBright, dolbyHdrCinema, dolbyHdrGame, expert1, expert2`. The G4 doc also lists `dolbyHdrDarkAmazon` and `hdrExternal` ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)). webOS 26 adds `creator, hdrCreator, dolbyHdrCreator` ([C2 on webOS 26 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_C2.md)).

Mapping from settings value to the `externalpq` `picMode` string. Sources: [bscpylgtv constants.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/constants.py) (accepted picMode strings), [PGenerator+ picture-mode catalogue](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/share/PGenerator/tv/lg/picture-modes/catalogue.json) (mapping and labels).

| Signal | UI label (2022+)                                | `pictureMode` setting                              | `picMode` for externalpq | Calibratable                                  |
| ------ | ----------------------------------------------- | -------------------------------------------------- | ------------------------ | --------------------------------------------- |
| SDR    | Cinema                                          | `cinema`                                           | `cinema`                 | yes                                           |
| SDR    | Expert (Bright Room)                            | `expert1`                                          | `expert1`                | yes                                           |
| SDR    | Expert (Dark Room)                              | `expert2`                                          | `expert2`                | yes                                           |
| SDR    | Game Optimizer                                  | `game`                                             | `game`                   | yes                                           |
| SDR    | FILMMAKER MODE                                  | `filmMaker`                                        | `filmMaker`              | yes                                           |
| SDR    | Technicolor Expert (older sets)                 | `technicolor`                                      | `technicolorExpert`      | yes (where present)                           |
| SDR    | Vivid, Standard, Eco, Sports, Personalized      | `vivid`, `normal`, `eco`, `sports`, `personalized` | none                     | no                                            |
| HDR10  | Cinema                                          | `hdrCinema`                                        | `hdr_cinema`             | yes                                           |
| HDR10  | Game Optimizer                                  | `hdrGame`                                          | `hdr_game`               | yes                                           |
| HDR10  | FILMMAKER MODE                                  | `hdrFilmMaker`                                     | `hdr_filmMaker`          | yes                                           |
| HDR10  | Cinema Home, Standard, Vivid, Eco, Personalized | `hdrCinemaBright`, …                               | none                     | no                                            |
| DV     | Cinema Home                                     | `dolbyHdrCinemaBright`                             | `dolby_cinema_bright`    | yes                                           |
| DV     | FILMMAKER MODE (called "Cinema" on 2019–2021)   | `dolbyHdrCinema`                                   | `dolby_cinema_dark`      | yes                                           |
| DV     | Game Optimizer                                  | `dolbyHdrGame`                                     | `dolby_game`             | yes                                           |
| HLG    | any                                             | `hdr*`                                             | none known               | PGenerator+ marks HLG calibration unsupported |

- Send DV picMode as `dolby_cinema_dark`, not `dolby_hdr_cinema_dark`. The latter makes `CAL_START` fail with errorCode 20 ([pgenerator-lg `lg_wire_pic_mode`](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg), hardware-verified 2026-07-23).
- Calman lists DV FILMMAKER MODE as "the only compatible mode for some 2024 LG TVs" ([Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)). For the B4, start DV work with `dolby_cinema_dark`.
- Game modes: bscpylgtv and Calman both list `game`, `hdr_game`, `dolby_game` as calibratable ([bscpylgtv README](https://github.com/chros73/bscpylgtv/blob/master/README.md), [Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)). Acceptance on a B4 with current firmware: **UNCONFIRMED**.

### 4.4 Picture keys relevant to calibration

Values and ranges from the webOS 24 G4 dump ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)). On webOS 24/25 most numbers are JSON **strings** (`"backlight":"100"`); webOS 26 returns some as numbers (`"gammaLevel":0`) ([G6 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G6.md)). Parse both. Writes accept numbers (README example) and strings (preset scripts) ([bscpylgtv README](https://github.com/chros73/bscpylgtv/blob/master/README.md), [lg-set-SDR-presets.py](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/setting_presets/lg-set-SDR-presets.py)).

| Key                                                                             | Type / range / enum                                                                           | UI meaning (UI label: UNCONFIRMED where marked)                                                                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pictureMode`                                                                   | enum (4.3)                                                                                    | Picture mode                                                                                                                                                                                                                                                                                                                  |
| `backlight`                                                                     | int 0–100                                                                                     | OLED Pixel Brightness ("OLED light")                                                                                                                                                                                                                                                                                          |
| `contrast`                                                                      | int 0–100                                                                                     | Contrast. Calman: 85 SDR, 100 HDR/DV                                                                                                                                                                                                                                                                                          |
| `brightness`                                                                    | int 0–100                                                                                     | Brightness ("Black Level" in the menu: UNCONFIRMED). Calman: 50                                                                                                                                                                                                                                                               |
| `color`                                                                         | int 0–100                                                                                     | Color saturation. Default 50                                                                                                                                                                                                                                                                                                  |
| `tint`                                                                          | int −50…50                                                                                    | Tint                                                                                                                                                                                                                                                                                                                          |
| `sharpness`                                                                     | int 0–50; also `hSharpness`, `vSharpness`                                                     | Sharpness                                                                                                                                                                                                                                                                                                                     |
| `colorGamut`                                                                    | `auto`, `native`, `wide`, `extended`, `dynamic`                                               | Color gamut. `CAL_START` forces `wide` (section 5.4)                                                                                                                                                                                                                                                                          |
| `gamma`                                                                         | `low` (1.9), `medium` (2.2), `high1` (2.4), `high2` (BT.1886); webOS 25+: `mediumHavingLevel` | Gamma. Exponents from the `wb22PointsGammaValue` tables (0.1^2.2 = 0.00631, 0.1^2.4 = 0.003981, 0.1^1.9 = 0.012589); `high2` = BT.1886: UNCONFIRMED                                                                                                                                                                           |
| `gammaLevel` (webOS 25+)                                                        | int −3…3                                                                                      | Fine step for `mediumHavingLevel` ([G5 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G5.md))                                                                                                                                                                                                  |
| `colorTemperature`                                                              | int −50…50                                                                                    | +50 = Warm 50, −50 = Cool 50 ([Light Illusion](https://lightillusion.com/forums/display-calibration-8/lg-oled-profiling-calibration-guides-775.html))                                                                                                                                                                         |
| `whiteBalanceColorTemperature`                                                  | `cool`, `medium`, `warm1`, `warm2`                                                            | Legacy colour-temperature preset (UNCONFIRMED)                                                                                                                                                                                                                                                                                |
| `dynamicContrast`                                                               | `off`, `low`, `medium`, `high`                                                                | Auto Dynamic Contrast. Off for calibration                                                                                                                                                                                                                                                                                    |
| `peakBrightness`                                                                | `off`, `high` (older sets: low/medium/high)                                                   | Peak Brightness                                                                                                                                                                                                                                                                                                               |
| `hdrDynamicToneMapping`                                                         | `on`, `off`, `HGIG`                                                                           | Dynamic Tone Mapping. Off for calibration ([Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/))                                                                                                                                                                                            |
| `DtmMastering1k` / `4k` / `10k`                                                 | int 10–100 step 10 (defaults 80/60/40)                                                        | Hidden static tone-map roll-off points per mastering peak (meaning: UNCONFIRMED; compare `1D_TONEMAP_PARAM`)                                                                                                                                                                                                                  |
| `DtmProfessional`                                                               | bool                                                                                          | UNCONFIRMED                                                                                                                                                                                                                                                                                                                   |
| `DtmMasteringLumMax`, `DtmToneMappingGain`, `DtmMasteringReset` (webOS 26)      | 0–10000, −5…5, bool                                                                           | Newer DTM controls ([G6 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G6.md))                                                                                                                                                                                                                 |
| `hgig` (webOS 25+)                                                              | `on`/`off`                                                                                    | UNCONFIRMED                                                                                                                                                                                                                                                                                                                   |
| `smoothGradation`                                                               | `off`, `low`, `medium`, `high`                                                                | Smooth Gradation. Off                                                                                                                                                                                                                                                                                                         |
| `noiseReduction`, `mpegNoiseReduction`                                          | `off`, `low`, `medium`, `high`, `auto`                                                        | Noise reduction. Off                                                                                                                                                                                                                                                                                                          |
| `superResolution`                                                               | `off`, `low`, `medium`, `high`                                                                | Super Resolution. Off                                                                                                                                                                                                                                                                                                         |
| `realCinema`                                                                    | `on`/`off`                                                                                    | Real Cinema (24p cadence). Not a colour control                                                                                                                                                                                                                                                                               |
| `truMotionMode`                                                                 | `off`, `cinemaClear`, `natural`, `smooth`, `user`, `clear`                                    | TruMotion; write with `current_app: true`                                                                                                                                                                                                                                                                                     |
| `motionProOLED`                                                                 | `off`, `low`, `medium`, `high`, `auto`                                                        | OLED Motion (BFI). Off for calibration (luminance changes)                                                                                                                                                                                                                                                                    |
| `motionEyeCare`                                                                 | `on`/`off`                                                                                    | Motion eye care (dims with motion). Off                                                                                                                                                                                                                                                                                       |
| `blackLevel`                                                                    | object `{ntsc, ntsc443, pal, pal60, palm, paln, secam, unknown}`, each `auto`/`low`/`high`    | Video Range / HDMI black level: `low` = limited, `high` = full ([Light Illusion](https://lightillusion.com/forums/display-calibration-8/lg-oled-profiling-calibration-guides-775.html)). ColorControl writes all 8 sub-keys ([LgTvApi.cs](https://github.com/Maassoft/ColorControl/blob/master/ColorControl/lgtv/LgTvApi.cs)) |
| `energySaving`                                                                  | `auto`, `off`, `min`, `med`, `max` (+ `screen_off`)                                           | Energy saving. Off for calibration ([Portrait](https://www.portrait.com/resource-center/2024-lg-autocal-guide/))                                                                                                                                                                                                              |
| `dynamicColor`                                                                  | `off`, `low`, `medium`, `high`, `user`                                                        | Dynamic colour. Off                                                                                                                                                                                                                                                                                                           |
| `dolbyPrecisionDetail`                                                          | `off`/`on` (only `off` observed)                                                              | DV Precision Detail                                                                                                                                                                                                                                                                                                           |
| `expressionEnhancer`                                                            | `off`, `detail`, `highlight`                                                                  |                                                                                                                                                                                                                                                                                                                               |
| `logoLuminanceAdjust`                                                           | `off`, `light`, `strong`                                                                      | Logo luminance (dims static areas; UNCONFIRMED effect on test windows)                                                                                                                                                                                                                                                        |
| `screenShift`                                                                   | `on`/`off`                                                                                    | Pixel shift                                                                                                                                                                                                                                                                                                                   |
| `colorManagement{Hue,Saturation,Luminance}{Red,Green,Blue,Cyan,Magenta,Yellow}` | int −30…30                                                                                    | 6-axis CMS                                                                                                                                                                                                                                                                                                                    |
| `adjustingLuminance`                                                            | int[22], each −50…50                                                                          | Per-point luminance in the 22-point WB menu                                                                                                                                                                                                                                                                                   |
| `adjustingLuminance10pt`                                                        | int[10]                                                                                       | Same, 10-point                                                                                                                                                                                                                                                                                                                |
| `filmMakerMode`, `isfMode`                                                      | `off` / `{expert1:"none",…}`                                                                  |                                                                                                                                                                                                                                                                                                                               |
| `externalPqlDbType`                                                             | `none`, `svl`, `calman`                                                                       | Which external PQ database is active (UNCONFIRMED meaning)                                                                                                                                                                                                                                                                    |
| `nearBlackDetail` (webOS 25+)                                                   | int −3…3 (C2 on webOS 26: −10…10)                                                             | UNCONFIRMED (candidate for "Fine Tune Dark Areas")                                                                                                                                                                                                                                                                            |

`aiPicture` category: `ai_Brightness`, `ai_Genre`, `ai_Picture` (`on`/`off`), `isAiPictureActing`. Switch all off for calibration ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md), [lg-set-SDR-presets.py](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/setting_presets/lg-set-SDR-presets.py)).

### 4.5 White balance encoding

| Key                                                    | Type                                                                         | Meaning                                                                                                      |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `whiteBalanceMethod`                                   | `"2"`, `"10"`, `"22"`, `"10code"`, `"22code"` (webOS 26: `"24"`, `"24code"`) | Active WB method. `…code` variants: UNCONFIRMED meaning (bscpylgtv uses `"22code"` with the 22-point arrays) |
| `whiteBalancePoint`                                    | `low` / `high`                                                               | Selected 2-point control (UI state)                                                                          |
| `whiteBalanceRedGain`, `…GreenGain`, `…BlueGain`       | int −50…50                                                                   | 2-point high (gain)                                                                                          |
| `whiteBalanceRedOffset`, `…GreenOffset`, `…BlueOffset` | int −50…50                                                                   | 2-point low (offset)                                                                                         |
| `whiteBalanceIre`                                      | one of `2.5, 5, 7.5, 10, 15, 20, …, 95, 100` (22 values)                     | Selected 22-point stimulus (UI state)                                                                        |
| `whiteBalanceIre10pt`                                  | `10, 20, …, 100`                                                             | Selected 10-point stimulus                                                                                   |
| `whiteBalanceCodeValue` / `…10pt`                      | string index (`"21"` = last of 22, `"9"` = last of 10)                       | Selected point index (UNCONFIRMED)                                                                           |
| `whiteBalanceRed`, `…Green`, `…Blue`                   | int[22], each −50…50                                                         | 22-point per-channel corrections, index 0 = 2.5 IRE … index 21 = 100 IRE                                     |
| `whiteBalanceRed10pt`, …                               | int[10]                                                                      | 10-point corrections                                                                                         |
| `whiteBalanceLuminance`                                | int 50–500                                                                   | Reference luminance for the luminance-adjust feature (UNCONFIRMED)                                           |
| `wb22PointsGammaValue` / `wb10PointsGammaValue`        | object `{low, medium, high1, high2(, mediumHavingLevel)}` → float[22]/[10]   | Target relative luminance per point for each gamma (read-only table). `high2` is all 1.0                     |
| `whiteBalancePattern`                                  | `outer`                                                                      | UNCONFIRMED                                                                                                  |

webOS 26 has 24 points: IRE list `1, 2, 3, 5, 7.5, 10, 15, …, 100` and int[24] arrays ([G6 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G6.md)). Branch on the array length you read.

Example write (luna; bscpylgtv HDR10 preset, [lg-set-HDR10-presets.py](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/setting_presets/lg-set-HDR10-presets.py)):

```json
{
  "category": "picture",
  "settings": {
    "whiteBalanceMethod": "22code",
    "whiteBalanceRed": [
      0, 2, 0, 1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -2, -2, -2, -1, -1,
      -2, 0, 0
    ],
    "whiteBalanceGreen": [
      1, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, -2, -2, -2, 0, 0, 0, 0, 0, 0
    ],
    "whiteBalanceBlue": [
      -1, 1, -1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 5, 3, 4, 4, 0, 0
    ],
    "whiteBalancePoint": "low",
    "whiteBalanceRedOffset": "0",
    "whiteBalanceGreenOffset": "0",
    "whiteBalanceBlueOffset": "0",
    "whiteBalanceRedGain": "0",
    "whiteBalanceGreenGain": "0",
    "whiteBalanceBlueGain": "0",
    "whiteBalanceCodeValue": "20"
  }
}
```

The WB arrays are in the public write allow-list on webOS 24, so the public `setSystemSettings` also takes them ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)). Once a custom 1D LUT is uploaded, "gamma, colorspace, and white balance settings in the user menu are greyed out" ([bscpylgtv README](https://github.com/chros73/bscpylgtv/blob/master/README.md)). On 2019+ models the 2-point WB values still apply on top.

### 4.6 HDMI-related keys (`other` category, luna writes unless noted)

From the webOS 24 G4 dump ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)):

| Key(s)                                                       | Values                                                                                | Meaning                                                                                                                                                               |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `uhdDeepColorHDMI1..4`                                       | observed `"off"`; generic `uhdDeepColor` enum `off`/`4k`; 8K variants `off`/`4k`/`8k` | HDMI Ultra HD Deep Colour per port. Public read/write on webOS 24. Exact per-port "on" value: UNCONFIRMED                                                             |
| `gameOptimization`, `gameOptimizationHDMI1..4`               | `on`/`off`                                                                            | Game Optimizer feature per input                                                                                                                                      |
| `enableALLM`                                                 | `on`/`off`                                                                            | ALLM. With ALLM the TV can jump to Game mode on its own ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)) |
| `hdmiPcMode`                                                 | `{"hdmi1":false,…}`                                                                   | PC mode per input (set through `eim/setDeviceInfo` icon `pc`)                                                                                                         |
| `eotf`, `eotfHDMI1..4`                                       | `auto`, `sdrGamma`, `hdrGamma`, `st2084`, `hlg`                                       | HDMI Signal Override: force EOTF                                                                                                                                      |
| `colorimetry`, `colorimetryHDMI1..4`                         | `auto`, `bt709`, `bt601`, `bt2020`, `p3D65`                                           | Force colorimetry                                                                                                                                                     |
| `masteringColorHDMI1..4`                                     | `auto`, `0`, `p3D65`, `bt2020D65`, `bt709D65`                                         | Force ST.2086 primaries                                                                                                                                               |
| `masteringPeakHDMI1..4`, `maxCLLHDMI1..4`, `maxFALLHDMI1..4` | `auto`, `0`, `400`, `540`, `700`, `1000`, `2000`, `3000`, `4000`, `10000`             | Force ST.2086 peak / MaxCLL / MaxFALL                                                                                                                                 |
| `444BypassHDMI1..4`                                          | `on`/`off`                                                                            | UNCONFIRMED                                                                                                                                                           |
| `dolbyVSVDBVerHDMI1..4`                                      | `v1`/`v2`                                                                             | DV VSVDB version advertised                                                                                                                                           |
| `blackStabilizer`, `whiteStabilizer`                         | int 0–20                                                                              | Game dashboard controls                                                                                                                                               |
| `lowLevelAdjustment`                                         | int −30…30                                                                            | UNCONFIRMED (candidate for "Fine Tune Dark Areas")                                                                                                                    |

The HDMI Signal Override keys let a SDR-only pattern source drive the HDR10 picture modes: set `eotfHDMIn = st2084` and `colorimetryHDMIn = bt2020` on that input. The menu itself opens with the key sequence `1113111` in picture settings on 2020+ models ([Light Illusion](https://lightillusion.com/forums/display-calibration-8/lg-oled-profiling-calibration-guides-775.html), [lg-toggle-HdmiSignallingOverride-2020.py](https://github.com/chros73/bscpylgtv/blob/master/docs/scripts/lg-toggle-HdmiSignallingOverride-2020.py)). bscpylgtv example: `set_settings other {"eotf":"hlg"}` ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)). Writing the per-port keys through luna on a B4: **UNCONFIRMED**.

Other categories: `network.wolwowlOnOff` (`"true"`/`"false"`), `option.quickStartMode` (`on`/`off`), `option.IPControlSecureKey` ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)).

### 4.7 Key differences by webOS version

| Change           | webOS 24 (G4 9.2.4)         | webOS 25 (G5 10.2.0)                                                              | webOS 26 (G6 11.1.0 / C2 11.2.0)                                                               |
| ---------------- | --------------------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| New picture keys | —                           | `filmmakerAmbientLight, gammaLevel, hgig, nearBlackDetail, precisionHdrMasterPro` | + `DtmMasteringLumMax, DtmMasteringReset, DtmToneMappingGain, aiHdrRemastering, colorWeakness` |
| `gamma` enum     | `low, medium, high1, high2` | + `mediumHavingLevel`                                                             | same as 25                                                                                     |
| WB points        | 2 / 10 / 22                 | 2 / 10 / 22                                                                       | 2 / 10 / 24                                                                                    |
| Number encoding  | strings                     | strings                                                                           | some numbers                                                                                   |
| Picture modes    | 4.3 list                    | same                                                                              | + `creator, hdrCreator, dolbyHdrCreator` (C2 on 26)                                            |

Sources: [G4](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md), [G5](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G5.md), [G6](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G6.md), [C2](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_C2.md) (diffed for this document).

---

## 5. Calibration API: `ssap://externalpq/setExternalPqData`

### 5.1 Request envelope

```json
{
  "id": 40,
  "type": "request",
  "uri": "ssap://externalpq/setExternalPqData",
  "payload": {
    "command": "1D_DPG_DATA",
    "picMode": "expert2",
    "profileNo": 0,
    "programID": 1,
    "data": "<base64>",
    "dataCount": 3072,
    "dataType": "unsigned integer16",
    "dataOpt": 1
  }
}
```

| Field       | Type   | Rule                                                                                                                                 | Source                                                                                                                                                                                                                                          |
| ----------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `command`   | string | Section 5.2                                                                                                                          | [cal_commands.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/cal_commands.py)                                                                                                                                                   |
| `picMode`   | string | bscpylgtv sends it on `CAL_START` only. Calman sends it on every externalpq command (captured 2026-07-23). Send it on every command. | [webos_client.py `calibration_request`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py), [pgenerator-lg `lg_calibration_request`](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg) |
| `profileNo` | int    | Always `0`                                                                                                                           | both                                                                                                                                                                                                                                            |
| `programID` | int    | Always `1`                                                                                                                           | both                                                                                                                                                                                                                                            |
| `data`      | string | Base64 (standard alphabet, padded) of the raw little-endian array                                                                    | both; float test vector `zczMPg…` = 0.4f LE ([tests](https://github.com/chros73/bscpylgtv/blob/master/tests/test_webos_client_calibration.py))                                                                                                  |
| `dataCount` | int    | Number of **elements** (not bytes)                                                                                                   | both                                                                                                                                                                                                                                            |
| `dataType`  | string | `"unsigned char"` (uint8), `"unsigned integer16"` (uint16), `"float"` (float32). A numeric code fails on C2 ("not a string").        | [constants.py `CALIBRATION_TYPE_MAP`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/constants.py), [pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)                               |
| `dataOpt`   | int    | `0` apply, `1` apply and save, `2` reset to factory (send `data:""`, `dataCount:0`)                                                  | [webos_client.py comment](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)                                                                                                                                           |

Omit `data`, `dataCount`, `dataType`, `dataOpt` on commands without data (bscpylgtv `CAL_START`, `CAL_END`).

Reset encoding: bscpylgtv builds an empty numpy array, so a reset request is `"data": "", "dataCount": 0, "dataOpt": 2` with the command's normal `dataType` ([webos_client.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py), [tests](https://github.com/chros73/bscpylgtv/blob/master/tests/test_webos_client_calibration.py)).

### 5.2 Command list

From [bscpylgtv cal_commands.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/cal_commands.py) and [webos_client.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py):

| Command                     | dataType                     | dataCount | Shape / values              | Purpose                                                 |
| --------------------------- | ---------------------------- | --------- | --------------------------- | ------------------------------------------------------- |
| `CAL_START`                 | none (or float × 9, see 5.4) | —         | —                           | Enter calibration mode for `picMode`                    |
| `CAL_END`                   | none                         | —         | —                           | Leave calibration mode and commit                       |
| `BACKLIGHT_UI_DATA`         | uint16                       | 1         | 0–100                       | OLED light (same as UI `backlight`)                     |
| `CONTRAST_UI_DATA`          | uint16                       | 1         | 0–100                       | Contrast                                                |
| `BRIGHTNESS_UI_DATA`        | uint16                       | 1         | 0–100                       | Brightness                                              |
| `COLOR_UI_DATA`             | uint16                       | 1         | 0–100                       | Color                                                   |
| `1D_DPG_DATA`               | uint16                       | 3072      | 3 × 1024, 0–32767           | Upload 1D LUT                                           |
| `1D_DPG_EN`                 | uint16                       | 1         | 0/1                         | 1D LUT enable ("?" in bscpylgtv: unused on some models) |
| `1D_2_2_EN`                 | uint16                       | 1         | 0/1                         | De-gamma (gamma → linear) before 3×3                    |
| `1D_0_45_EN`                | uint16                       | 1         | 0/1                         | Re-gamma (linear → gamma) after 3×3                     |
| `BT709_3D_LUT_DATA`         | uint16                       | N³ × 3    | N × N × N × 3, 0–4095       | 3D LUT used for BT.709-flagged input                    |
| `BT2020_3D_LUT_DATA`        | uint16                       | N³ × 3    | same                        | 3D LUT used for BT.2020-flagged input                   |
| `3BY3_GAMUT_EN`             | uint16                       | 1         | 0/1                         | 3×3 enable ("?": unused on some models)                 |
| `BT709_3BY3_GAMUT_DATA`     | float                        | 9         | 3 × 3 row-major, −1024…1024 | 3×3 matrix, BT.709 path                                 |
| `BT2020_3BY3_GAMUT_DATA`    | float                        | 9         | same                        | 3×3 matrix, BT.2020 path                                |
| `HDR_3BY3_GAMUT_DATA`       | float                        | 9         | same                        | 2019 models only                                        |
| `1D_TONEMAP_PARAM`          | uint16                       | 7         | see 5.9                     | HDR10 static tone curve (HDR10 modes only)              |
| `DOLBY_CFG_DATA`            | uint8 (`"unsigned char"`)    | bytes     | ASCII text, CRLF            | Dolby Vision display config (DV modes only)             |
| `PTN_SINGLE_WINBOX_ATTR`    | —                            | —         | own fields (5.11)           | iTPG window                                             |
| `PTN_SINGLE_GRADATION_ATTR` | —                            | —         | own fields                  | iTPG gradient bar                                       |
| `PTN_CTRL`                  | —                            | —         | own fields                  | iTPG on/off                                             |

Read commands for `externalpq/getExternalPqData` (payload `{"command": …}`): `GET_1D_DPG_DATA`, `GET_3D_LUT_DATA`, `GET_1D_2_2_EN`, `GET_1D_0_45_EN`, `GET_3BY3_GAMUT_DATA`, `GET_HDR_3BY3_GAMUT_DATA`.

The image pipeline bscpylgtv refers to: [displaycalibrations.com LG OLED signal chain diagram](https://displaycalibrations.com/images/LG_OLED_Video_Signal_Chain_Diagram_Picture.png). Order of the 3D LUT relative to the 1D LUT: **UNCONFIRMED** from text sources; the diagram shows it.

### 5.3 Byte layouts (all little-endian)

Verified: the hashes below match the base64 payloads in bscpylgtv's test fixtures ([tests/expected](https://github.com/chros73/bscpylgtv/tree/master/tests/expected)) byte for byte.

**1D LUT (`1D_DPG_DATA`)**

- uint16 × 3072, planar: R[0…1023], then G[0…1023], then B[0…1023] ([lut_tools.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/lut_tools.py): shape `(3,1024)`, `tobytes()`).
- Index i corresponds to input code i/1023 of the internal 10-bit signal. Values are 15-bit, 0–32767.
- Unity, bscpylgtv: `round(i * 32767 / 1023)` for every channel. 6144 bytes, base64 length 8192, SHA-256 `51a5362cea91bfcea487c7160c249f3ae0380fc4d3028b6c0b5036dfafa0dd80`.
- Unity, Calman capture: `i * 32` (last value 32736). SHA-256 `351e9a3ca08b509767a04ad8080300980f97b63580804549cfbe8c7e50681af6`, base64 starts `AAAgAEAAYACAAKAAwADgAAAB` ([pgenerator-lg `lg_unity_1d_lut`](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)).
- From ArgyllCMS `.cal` or `.cube`: interpolate to 1024 points, multiply by 32767, round, transpose to planar ([lut_tools.py `read_cal_file`, `read_cube_file`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/lut_tools.py)).

**3D LUT (`BT709_3D_LUT_DATA`, `BT2020_3D_LUT_DATA`)**

- uint16 × N³ × 3. Node order: **R fastest, then G, then B slowest**. Each node is the triplet (R_out, G_out, B_out) ([pgenerator-lg 3D probe](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg): `payload_axis_order => "R fastest, G middle, B slowest"`; bscpylgtv `unity_lut_3d` and `.cube` reshape agree).
- This equals the `.cube` file row order; bscpylgtv reads a `.cube` straight into the payload ([lut_tools.py `read_cube_file`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/lut_tools.py)).
- Values are 12-bit, 0–4095. Encoding of a normalized value v: `min(round(v * 4096), 4095)`. Grid node k of N has input `k * 4096 / (N − 1)`, so the top node clips to 4095.
- Byte offset of node (r, g, b), channel c: `2 * (3 * (r + N*g + N*N*b) + c)`.
- B4: N = 17 → 14739 values, 29478 bytes, base64 length 39304. Unity SHA-256 `7bf3000f247f76254a920e17b1ed23e6e12edacfbf493c99f7527e5f9b3e44ab`. First nodes: (0,0,0), (256,0,0), (512,0,0).
- N = 33 → 107811 values, 215622 bytes, base64 length 287496. Unity SHA-256 `ac797aeab6521e160c8cf765662b8bd7cd608e4b1512dbc12587d75d03d39391`.
- Light Illusion reports LG's internal 3D LUTs work at "64-1023 (EXTENDED), with HDMI Black Level @ LOW", contrast 85 ([Light Illusion forum](https://lightillusion.com/forums/display-calibration-8/lg-oled-profiling-calibration-guides-775.html)). Treat the input domain mapping as **UNCONFIRMED** and verify with measurements.

**3×3 matrix**

- float32 × 9, row-major `[[m00,m01,m02],[m10,m11,m12],[m20,m21,m22]]` ([lut_tools.py `read_3by3_gamut_file`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/lut_tools.py)). Range check −1024…1024.
- Identity base64: `AACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAAAAAAIA/`.
- Whether the TV computes `out = M · in` (column vector) or `in · M`: **UNCONFIRMED**. Probe with a non-symmetric matrix and measure.

**Flags and UI data**: uint16 × 1. `0` → `AAA=`, `1` → `AQA=`, `39` → `JwA=`, `50` → `MgA=`, `85` → `VQA=`, `100` → `ZAA=`.

**Tone-map parameters**: uint16 × 7 (section 5.9). `[760,1000,75,4000,60,10000,50]` → `+ALoA0sAoA88ABAnMgA=`.

**DOLBY_CFG_DATA**: the config text as bytes (`"unsigned char"`), `dataCount` = byte length, lines ending in `\r\n` ([webos_client.py `set_dolby_vision_config_data`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).

### 5.4 Session rules and side effects

Sequence (bscpylgtv README example, [README](https://github.com/chros73/bscpylgtv/blob/master/README.md)):

1. Switch to the input and the target picture mode. Send the matching signal class: "to upload calibration data for HDR10 picture modes, one has to send the TV an HDR10 signal or play an HDR10 file, and similarly for Dolby Vision" ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
2. `CAL_START` with `picMode`.
3. UI data, bypass/reset, 1D LUT, 3D LUT, matrices, tone map or DV config.
4. `CAL_END`.

Rules and observations:

- "Calibration commands can only be run while in calibration mode (controlled by `start_calibration` and `end_calibration`)" ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
- `CAL_START` forces colour temperature to Warm 50 and `colorGamut` to `wide` ([calibrating_hdr10 guide](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/calibrating_hdr10/README.md), [profiling_sdr guide](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/profiling_sdr/README.md)). If you only correct white balance, set `colorGamut` back to `auto` (SDR/HDR) or `native` (DV) after `CAL_END` ([mitigating_dovi_raised_black guide](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/mitigating_dovi_raised_black/README.md)). bscpylgtv's own presets set `colorGamut:"native"` after a custom 3D LUT ([lg-set-SDR-presets.py](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/setting_presets/lg-set-SDR-presets.py)). Which `colorGamut` value selects the uploaded 3D LUT on a B4: **UNCONFIRMED**.
- In calibration mode the HDR10 tone mapping is bypassed ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)). "LG calibrates at a 2.2 gamma curve with HDR/DV processing disabled" ([Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)). In HDR10/DV calibration mode the 1D LUT target is therefore gamma 2.2 + D65, not ST 2084.
- `CAL_START` payload variants:
  - bscpylgtv: `{"command":"CAL_START","profileNo":0,"programID":1,"picMode":"expert1"}` ([tests](https://github.com/chros73/bscpylgtv/blob/master/tests/test_webos_client_calibration.py)).
  - Calman (captured): the same plus 9 zero floats: `"data":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","dataCount":9,"dataType":"float","dataOpt":1`. Without `picMode` a C2 answers `500 Application error` ([pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)).
  - aiopylgtv sent 9 floats `[0,0,0,0,0,0,0.0044,−0.0453,1.041]` on both `CAL_START` and `CAL_END` ([aiopylgtv constants.py](https://github.com/bendavid/aiopylgtv/blob/master/aiopylgtv/constants.py)). Meaning: **UNCONFIRMED**.
  - Recommended for the B4: try the bscpylgtv form; on `500`, retry with the Calman form.
- `CAL_START` can fail once with errorCode 20 and succeed on retry. PGenerator+ retries after re-reading the picture mode ([lg_calibration_start_retry.t](https://github.com/oldgithubman/PGenerator-Plus/blob/main/t/lg_calibration_start_retry.t)).
- Some DV firmware returns errorCode 20 on `CAL_START`/`CAL_END` but still accepts the data commands on the same socket ([pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)).
- DV `CAL_START` fails with the opaque driver error unless the source sends DV in **relative** mode ([lg_cal_hist_reupload_dv_map_mode.t](https://github.com/oldgithubman/PGenerator-Plus/blob/main/t/lg_cal_hist_reupload_dv_map_mode.t)).
- Do not send `CAL_END` after an explicit `CAL_START` rejection; it can close another client's session. Send `CAL_END` on the same socket if `CAL_START` timed out ([pgenerator-lg `lg_calibration_start_cleanup_if_safe`](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)). If `CAL_END` is unconfirmed, restart the TV before the next session.
- bscpylgtv's scripts wait 3 s after `set_system_picture_mode`, `CAL_START`, each upload and `CAL_END` ([lg-set-SDR-presets.py](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/setting_presets/lg-set-SDR-presets.py)).
- Calibration data is stored per picture mode; SDR, HDR10(+HLG) and DV modes are separate ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md); [Portrait](https://www.portrait.com/resource-center/2024-lg-autocal-guide/): "Each picture mode stores its calibration separately"). Whether one upload applies to the same mode on every HDMI input: **UNCONFIRMED** (UI settings are per input, section 4.2).
- 3D LUT slot choice: SDR and HDR10 modes pick the BT.709 or BT.2020 LUT from the signal's colorimetry flags; DV appears to use only the BT.709 LUT ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
- A custom 1D LUT disables the service-menu white balance and greys out user gamma, colour space and WB ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
- `set_1d_en_*` and `set_3by3_gamut_data_*` "should only be used with unity/custom 3D LUT" ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
- Upload transport failures: PGenerator+ re-runs the whole bracket (`CAL_START` … readback … `CAL_END`) with bounded exponential backoff ([pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)).

### 5.5 Model-year table (bscpylgtv `calibration_support_info`)

Chip type = `model_name[7:11]` of `getCurrentSWInformation` ([webos_client.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py), [tests](https://github.com/chros73/bscpylgtv/blob/master/tests/test_webos_client_lite.py)):

| Chip types                            | 3D LUT | DV config format |
| ------------------------------------- | ------ | ---------------- |
| `W17H`, `W17O`                        | none   | none             |
| `W18H`                                | 17     | 2018             |
| `W18O`                                | 33     | 2018             |
| `W19H`…`W26H` (incl. **`W24H` = B4**) | 17     | 2019             |
| `W19O`…`W26O`, `W24G`, `W25G`, `W26G` | 33     | 2019             |

- Support for 2024 and 2025 OLEDs arrived in bscpylgtv v0.4.7; 2026 in v0.5.2 ([CHANGELOG](https://github.com/chros73/bscpylgtv/blob/master/CHANGELOG.md)).
- Only the 3D LUT and DV config commands depend on this table; other commands work without it ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
- 3×3 gamut: every listed chip accepts the BT.709/BT.2020 commands in bscpylgtv. `HDR_3BY3_GAMUT_DATA` is "only used in 2019 models" ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
- Tone-map parameters and iTPG: 2019 and newer ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
- If `getCurrentSWInformation` is denied, detect the LUT size with `GET_3D_LUT_DATA`: `dataCount` 14739 → 17, 107811 → 33 ([pgenerator-lg `lg_3d_lut_size_from_count`](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)).

### 5.6 Calibration bank picMode strings accepted

`cinema, expert1, expert2, game, technicolorExpert, filmMaker` (SDR); `hdr_cinema, hdr_game, hdr_technicolorExpert, hdr_filmMaker` (HDR10 + HLG); `dolby_cinema_bright, dolby_cinema_dark, dolby_game` (DV) ([constants.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/constants.py)). Mapping to settings values: section 4.3.

### 5.7 Readback: yes, with caveats

Reading back **is possible** through `ssap://externalpq/getExternalPqData` ([bscpylgtv README "Get calibration commands"](https://github.com/chros73/bscpylgtv/blob/master/README.md)):

```json
{
  "id": 50,
  "type": "request",
  "uri": "ssap://externalpq/getExternalPqData",
  "payload": { "command": "GET_1D_DPG_DATA" }
}
```

Reply payload: `{"returnValue":true,"data":"<base64>","dataCount":3072,"dataType":"unsigned integer16"}`. The TV writes the data to a temp file; the SSAP adapter base64-encodes it, deletes the file and drops the `path` field ([apiadapter source quoted in aiopylgtv #44](https://github.com/bendavid/aiopylgtv/issues/44)).

Caveats:

- "they can be partially or completely broken (depending on firmware version, picture preset, etc)"; they work inside or outside calibration mode; they return the **active** picture mode's data; factory LUTs come back "post-processed … with all customizations factored in" ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
- A C2 read a reset unity 1D LUT back with green max 32682 instead of 32767 ([pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)). Compare readback with a tolerance.
- PGenerator+ marks readback as supported on 2022+ platforms including `W24H`, and not on 2020–2021 ([platforms/webos-2020-2026.json](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/share/PGenerator/tv/lg/platforms/webos-2020-2026.json)).
- Without data the reply is `500 Application error` with `errorText: "no file path from tvservice"` ([aiopylgtv #44](https://github.com/bendavid/aiopylgtv/issues/44)).
- No getter is known for UI data, the tone-map parameters or the DV config.

### 5.8 Bypass ("DDC reset") and factory reset

Bypass = unity data. bscpylgtv calls SDR bypass "also known as DDC reset" ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)); Calman calls it "Full DDC Reset" ([Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)). TFTCentral: Full DDC reset "removes that factory profile and starts everything from new for the selected picture mode" ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)).

| Sequence (inside `CAL_START`…`CAL_END`) | Commands ([webos_client.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py))                                                                                |
| --------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SDR bypass                              | `1D_2_2_EN`=0, `1D_0_45_EN`=0, `BT709_3BY3_GAMUT_DATA`=identity, `BT2020_3BY3_GAMUT_DATA`=identity, `BT709_3D_LUT_DATA`=unity, `BT2020_3D_LUT_DATA`=unity, optional `1D_DPG_DATA`=unity |
| HDR10 bypass                            | `1D_DPG_DATA`=unity; optional: the six SDR commands above                                                                                                                               |
| DV bypass                               | `1D_DPG_DATA`=unity                                                                                                                                                                     |
| SDR factory reset                       | the seven SDR commands with `dataOpt:2` and empty data                                                                                                                                  |
| HDR10 factory reset                     | the same + optional `1D_TONEMAP_PARAM` with `dataOpt:2`                                                                                                                                 |
| DV factory reset                        | `1D_DPG_DATA` with `dataOpt:2` + optional `DOLBY_CFG_DATA` with `dataOpt:2`                                                                                                             |

The old aiopylgtv `ddc_reset(picMode, reset_1d_lut=True)` is the SDR bypass ([aiopylgtv webos_client.py](https://github.com/bendavid/aiopylgtv/blob/master/aiopylgtv/webos_client.py)). Before `dataOpt:2` existed, a factory reset of the picture mode in the menu was the only way back ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).

### 5.9 Tone-map parameters (`1D_TONEMAP_PARAM`)

Seven uint16 values, in this order ([webos_client.py `set_tonemap_params`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)):

| Index | Name                         | Range     | bscpylgtv default |
| ----- | ---------------------------- | --------- | ----------------- |
| 0     | panel peak luminance (cd/m²) | 100–4000  | 700               |
| 1     | mastering_peak_1             | 100–10000 | 1000              |
| 2     | rolloff_point_1 (%)          | 0–100     | 70                |
| 3     | mastering_peak_2             | 100–10000 | 4000              |
| 4     | rolloff_point_2 (%)          | 0–100     | 60                |
| 5     | mastering_peak_3             | 100–10000 | 10000             |
| 6     | rolloff_point_3 (%)          | 0–100     | 50                |

- Only for HDR10 picture modes (`hdr_*`); bscpylgtv rejects others ([webos_client.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)). bscpylgtv does not send `picMode` with it.
- Semantics (interpretation of the parameter names; UNCONFIRMED in detail): for content mastered at peak _k_, the curve tracks PQ up to _rolloff_k_ % of the panel peak, then rolls off to the panel peak. All roll-off points at 100 "disable internal tonemapping entirely" ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)). The hidden picture keys `DtmMastering1k/4k/10k` (defaults 80/60/40) look like the same knobs (UNCONFIRMED).
- Calman: measure the HDR peak on a 10% window, enter it, press "Tone Curve Upload", "no other values should be changed" ([Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)). TFTCentral: take about five peak readings, because the 10% window "warms up" ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)).
- Examples in bscpylgtv: `hdr_cinema 760 1000 75 4000 60 10000 50`; presets `870/950 1000 100 4000 100 10000 100` ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md), [lg-set-HDR10-presets.py](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/setting_presets/lg-set-HDR10-presets.py)).
- Dynamic Tone Mapping: Calman requires DTM **off** for calibration and validation ([Portrait](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)). With DTM `on` the TV tone-maps per frame; whether the uploaded static curve still matters: UNCONFIRMED. With `HGIG` the TV is meant to stop tone mapping at the panel peak so the console does it ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)); interaction with `1D_TONEMAP_PARAM`: UNCONFIRMED.

### 5.10 Dolby Vision configuration

Purpose: tell the TV's Dolby Vision display manager the real panel peak, black and primaries after the 1D LUT is calibrated to gamma 2.2/D65.

**Format "2019" (bscpylgtv default for 2019+ chips, USB file)** ([lut_tools.py `create_dolby_vision_config`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/lut_tools.py)):

```
# Dolby Vision User Display Configuration File
# Generated by bscpylgtv on 2026-10-31
# Display: Unspecified
# DM Version:
[PictureMode = 2]
Tmax = 750.0000
Tmin = 0.0001
Tgamma = 2.2
TPrimaries = 0.6796 0.3187 0.2595 0.6849 0.1448 0.0494 0.3127 0.3290
```

- Header lines only once, before the first block. `# DM Version: ` ends with a space.
- One `[PictureMode = N]` block per DV mode. N: 1 = Cinema Home (`dolby_cinema_bright`), 2 = Cinema/FILMMAKER (`dolby_cinema_dark`), 4 = Game (`dolby_game`) ([constants.py `DV_PICTURE_MODES`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/constants.py)). LG's factory file also has 0 = Vivid and 3 = Standard ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)).
- `Tmax` = measured white (cd/m², 100–4000), format `%.4f`. `Tmin` = black (default 0.0001, 0–0.99). `Tgamma` = 2.2. `TPrimaries` = xr yr xg yg xb yb xw yw, `%.4f`; white is always D65 0.3127 0.3290.
- Files in bscpylgtv's guides use the same bracketed format with the header `# Generated by 5.10.2.67 on 30/03/2024` (a Calman 5-style version number; attribution UNCONFIRMED) and blocks with `DBrightness`/`Tmax`/`TPrimaries` ([setting_presets DolbyVision_UserDisplayConfiguration.txt](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/setting_presets/DolbyVision_UserDisplayConfiguration.txt), [mitigating_dovi_raised_black copy](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/mitigating_dovi_raised_black/DolbyVision_UserDisplayConfiguration.txt)). The version in the header is the generating software's version; the TV does not seem to check it (UNCONFIRMED).
- Lines are CRLF. File name `DolbyVision_UserDisplayConfiguration.txt` ([constants.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/constants.py)).

**Format "2018" (2018 chips; and what Calman sent over `DOLBY_CFG_DATA` in a 2026 capture)**:

```
PictureMode = 2
Tmax = 710.0000
Tmin = 0.0001
Tgamma = 2.2
ColorPrimaries = 0.6796 0.3187 0.2595 0.6849 0.1448 0.0494 0.3127 0.3290
TLMS2RGBmat = 4.18278398329451 -3.30049295101940 0.117749870955320 -0.882467140762750 2.01734548281183 -0.134865869784530 0.0437827473048400 -0.107670286757020 1.06391551060750
```

- `TLMS2RGBmat` = inverse(RGB→XYZ of the primaries with D65) × inverse(XYZ→LMS), XYZ→LMS = `[[0.4002, 0.7076, −0.0808], [−0.2263, 1.1653, 0.0457], [0, 0, 0.9182]]`, printed `%#.15g` row-major ([lut_tools.py `lms2rgb_matrix`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/lut_tools.py); exact test vector above from [tests](https://github.com/chros73/bscpylgtv/blob/master/tests/test_webos_client_calibration.py)). PGenerator+ uses the more precise matrix `[[0.400238220153002, 0.707593156246992, −0.080805581487871], [−0.226298103801373, 1.165315591308231, 0.045700774541672], [0, 0, 0.918224951158247]]`, which it says reproduces a Calman upload ([pgenerator-lg `lg_dv_profile_lms2rgb_matrix`](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)).
- PGenerator+ claims Calman's `DOLBY_CFG_DATA` upload uses this unbracketed format with `PictureMode = 2` as a fixed constant, a `# Dolby Vision User Display Configuration File` header, and only `Tmax` measured for white (white chromaticity fixed at D65), hardware-verified 2026-07-23 on an unnamed model ([pgenerator-lg `lg_dv_profile_descriptor`](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)). Which format a B4 accepts over the API: **UNCONFIRMED**.

Upload paths:

1. API: `DOLBY_CFG_DATA` inside `CAL_START`/`CAL_END` for a DV picMode, `dataType "unsigned char"`. bscpylgtv marks this "not recommended on >=2020 models!" ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
2. USB: put the file in the root of a USB stick, plug it in, play DV content; a popup offers Update/Restore. luna `com.webos.service.pqcontroller/setProperties {"dolbyCfgAlertReturn":"Update"}` answers it. The popup is disabled for a DV mode that holds API-uploaded data (for example a custom 1D LUT); update the config first, or reset the mode ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).

What Calman measures for the DV config: "White, Black, Red, Green, and Blue measurement data", after the 1D LUT AutoCal ("LG 20 Points HDR", B 50, C 100) to 2.2 gamma and D65, with the pattern source sending DV **Relative** mode metadata; validation then switches to **Absolute** mode against P3/D65/ST 2084 ([Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/), [TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)). Measured picture mode: the DV mode being calibrated (DV FILMMAKER on some 2024 sets). The LG internal generator needs no metadata switch (α9/α11 only).

B4 factory values (for sanity checks): panel `Tmax 720`, `Tmin 0.0001`, primaries `0.6799 0.3194 0.2626 0.6754 0.1445 0.0512`; mode Tmax: Vivid 252, Cinema Home 360, Standard 360, Game 360; Cinema `SupportsDM3 = 1`, `BrightnessPreservation = 0` ([G4 doc](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md)).

### 5.11 Internal test pattern generator (iTPG)

Sent with `externalpq/setExternalPqData` but with their own fields ([webos_client.py `set_itpg_*`, `toggle_itpg`](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)):

Three example payloads, one per command:

```json
[
  {
    "command": "PTN_SINGLE_WINBOX_ATTR",
    "fillR": 940,
    "fillG": 940,
    "fillB": 940,
    "winId": 1,
    "width": 1214,
    "height": 683,
    "startX": 1313,
    "startY": 738,
    "programID": 1
  },
  {
    "command": "PTN_SINGLE_GRADATION_ATTR",
    "barId": 0,
    "strideSize": 3,
    "startR": 0,
    "startG": 0,
    "startB": 0,
    "stepR": 1,
    "stepG": 1,
    "stepB": 1,
    "programID": 1
  },
  {
    "command": "PTN_CTRL",
    "enable": "true",
    "numOfBox": 2,
    "ptnType": 0,
    "programID": 1
  }
]
```

- Colours are 10-bit. ≥2020 models want limited range (64–940) in HDR10; DV wants full range (0–1023) ([README](https://github.com/chros73/bscpylgtv/blob/master/README.md)).
- Up to 10 windows (`winId` 0–9, 0 at the back), up to 4 gradient bars. Geometry is in panel pixels (3840×2160) regardless of the signal.
- `enable` is the string `"true"`/`"false"` on newer firmware (a bool on older).
- `ptnType`: 0 windows, 1 vertical bars, 2 horizontal bars.
- The window above is a 10% window computed like bscpylgtv's measurement script ([lg-itpg-manual-measure-from-csv.py](https://github.com/chros73/bscpylgtv/blob/master/docs/scripts/lg-itpg-manual-measure-from-csv.py)).
- Works inside or outside calibration mode. Availability on the α8 B4: **UNCONFIRMED** (Calman only offers it on α9/α11).

### 5.12 Known restrictions and regressions

| Restriction                                    | Detail                                                                                                                                                                                                                                  | Source                                                                                                                                         |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| webOS 26 (fw 43.x)                             | `CAL_START`/`setExternalPqData` → `401 insufficient permissions` for third parties; some picture writes → `500 … Some keys are not allowed`. Calman/Light Illusion use LG partner identities; whether those still work on 43.x is open. | [PGenerator+ #70](https://github.com/oldgithubman/PGenerator-Plus/issues/70), [#71](https://github.com/oldgithubman/PGenerator-Plus/issues/71) |
| Factory-disabled EU SKUs                       | e.g. 55C41LA, 83C43LA, 55G42LW, 77G51LW, 83G51LW                                                                                                                                                                                        | [AVS Forum](https://www.avsforum.com/threads/lg-oled-eu-tvs-2024-2025-calibration-capability-database.3330101/)                                |
| DV relative mode                               | DV `CAL_START` needs relative-mode DV input                                                                                                                                                                                             | [PGenerator+ test](https://github.com/oldgithubman/PGenerator-Plus/blob/main/t/lg_cal_hist_reupload_dv_map_mode.t)                             |
| Wrong DV picMode spelling                      | `dolby_hdr_*` → errorCode 20                                                                                                                                                                                                            | [pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg)                                              |
| Readback                                       | partly broken on some firmware                                                                                                                                                                                                          | [README](https://github.com/chros73/bscpylgtv/blob/master/README.md)                                                                           |
| 2023 webOS update                              | A Light Illusion thread reported a webOS update that broke calibration connections, "killed Calman operation too"                                                                                                                       | [Light Illusion forum](https://lightillusion.com/forums/display-calibration-8/lg-interaction-latest-release-webos-1001.html)                   |
| webOS 23/24 regressions specific to externalpq | none found beyond the above                                                                                                                                                                                                             | —                                                                                                                                              |

---

## 6. Licences

| Project                                      | Licence                                              | Use in this app                                                                    | Source                                                                                                                                             |
| -------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| bscpylgtv                                    | MIT (© 2017 Dennis Karpienski, © 2019 Josh Bendavid) | Protocol facts free to use; copying code or the manifest JSON needs the MIT notice | [LICENSE.txt](https://github.com/chros73/bscpylgtv/blob/master/LICENSE.txt)                                                                        |
| aiopylgtv                                    | MIT (same holders)                                   | same                                                                               | [LICENSE](https://github.com/bendavid/aiopylgtv/blob/master/LICENSE)                                                                               |
| lgtv2                                        | MIT (© Sebastian Raff)                               | same                                                                               | [LICENSE](https://github.com/hobbyquaker/lgtv2/blob/master/LICENSE), [package.json](https://github.com/hobbyquaker/lgtv2/blob/master/package.json) |
| PyWebOSTV, LGWebOSRemote, webosbrew/caniroot | MIT                                                  | same                                                                               | GitHub API licence field                                                                                                                           |
| aiowebostv, lgtv_manager, Connect SDK        | Apache-2.0                                           | Facts free; copied code needs the Apache notice                                    | [aiowebostv LICENSE](https://github.com/home-assistant-libs/aiowebostv/blob/main/LICENSE)                                                          |
| PGenerator-Plus, LG_Buddy, ColorControl      | GPL-3.0                                              | **Facts only. Do not copy code** into a non-GPL app                                | GitHub API licence field                                                                                                                           |

- Interface facts (URIs, field names, enum strings, byte layouts, numbers) are not the projects' copyrightable expression; reimplementing them from this document is the normal way these libraries were built. This is not legal advice.
- The signed manifest's `signature` belongs to LG (from LG's own remote app). Every MIT library above ships it. LG blacklisted it on webOS 26. Ship it as a separate data file with attribution, and keep manifest B as the fallback.
- LG does not document SSAP or externalpq publicly. Partner calibration identities are granted under commercial agreements ([PGenerator+ #71](https://github.com/oldgithubman/PGenerator-Plus/issues/71)).

---

## 7. Practical calibration behaviour on a 2024 LG OLED

### 7.1 Measurement conditions

- Window: 10% window for SDR, HDR and DV on OLED ([Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)).
- Anti-dimming pattern insertion (Calman defaults, OLED only):
  - SDR: frequency 45, duration 5, pattern level 25; stabilization 1 patch, duration 1, level 10.
  - HDR/DV: frequency 5, duration 5, level 25; same stabilization.
  - Purpose: "periodically inserts a different test pattern … to reset the display's auto-dimming timer" ([Portrait](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)). Units: UNCONFIRMED (read as "every 45 patches, show a 25% field for 5 s").
- Dimming algorithms behind this: Temporal Peak Control and Global Stress Reduction (service menu; bscpylgtv can switch them on 2020+) ([bscpylgtv README](https://github.com/chros73/bscpylgtv/blob/master/README.md)). Do not switch them off by default; they protect the panel.
- Warm-up: about 30 minutes before calibrating; 100–200 hours break-in for a new panel ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)).
- Settle time: wait ≥ 3 s after a picture-mode change or a calibration command ([lg-set-SDR-presets.py](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/setting_presets/lg-set-SDR-presets.py)); ≥ 1 s before reading a setting back ([LG_Buddy](https://github.com/Staphylococcus/LG_Buddy/blob/main/crates/lg-buddy/src/web_os/picture.rs)). Then read the meter until consecutive readings agree.
- Settings to switch off: Energy Saving, Dynamic Tone Mapping (both required by Calman); AI Picture, AI Brightness (AI Brightness also enables DV IQ); TruMotion/BFI, noise reduction, dynamic contrast, smooth gradation ([Portrait](https://www.portrait.com/resource-center/2024-lg-autocal-guide/), [TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration), [bscpylgtv presets](https://github.com/chros73/bscpylgtv/blob/master/docs/guides/setting_presets/lg-set-SDR-presets.py)).
- Video range: Calman's LG AutoCal is "not designed to work for 'PC (0 – 255)' mode"; use video levels and PC mode off ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)).
- Pixel refresh: the TV runs an automatic compensation cycle when switched off with the remote after 4 or more hours of use. Keep it plugged in until done ([LG support](https://www.lg.com/ae/support/product-help/CT20076005-20153292130516OLT)). The short cycle takes about 7–10 minutes; the long one about an hour after ~2000 hours ([BGR](https://bgr.com/2098397/how-often-oled-displays-need-pixel-cleaning/)). After `system/turnOff`, do not wake the TV for a new session for about 10 minutes, and expect `getPowerState` to show `Active Standby` meanwhile (UNCONFIRMED).

### 7.2 Picture-mode features

- Expert modes (`expert1`/`expert2`) are LG's ISF calibration modes ([LG support](https://www.lg.com/lk/support/product-help/CT30012353-1436494367250)). Calman's SDR list: Cinema, Expert Bright, Expert Dark, Game, Filmmaker ([Portrait](https://www.portrait.com/resource-center/2024-lg-autocal-guide/)).
- Peak Brightness (`peakBrightness`) raises the ABL limit; keep it the same during and after calibration.
- "Fine Tune Dark Areas": key mapping UNCONFIRMED (candidates `lowLevelAdjustment`, `nearBlackDetail`). TFTCentral warns that shadow-detail tweaks outside the calibration session "will reset your 1D LUT greyscale calibration" ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)).
- Changing OLED light after calibration shifts gamma and colour slightly ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)). Calibrate at the final OLED light, or set it 15% above target before the 1D LUT step and re-trim (Calman).

### 7.3 Game Optimizer

- Game Optimizer is a picture mode (`game`, `hdrGame`, `dolbyHdrGame`) plus per-input switches (`gameOptimizationHDMIn`). LG locks some picture settings while it is on ([LG support](https://www.lg.com/us/support/help-library/lg-tv-how-to-use-the-game-optimizer-CT10000018-20153207342504)). Exactly which processing it disables on webOS 24/25: UNCONFIRMED.
- ALLM can switch an input into Game mode by itself. Switch ALLM off (`enableALLM`) on the calibration input so the mode does not change mid-run ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)).
- Game modes are calibration banks (section 4.3).

### 7.4 HDR10 tone-mapping settings

- Calibrate with `hdrDynamicToneMapping = off` (Calman requirement). The static curve from `1D_TONEMAP_PARAM` then applies.
- HGiG means the source does the tone mapping; set it after calibration if the user's source supports HGiG ([TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)).

### 7.5 Calman LG AutoCal workflow (to mirror)

From [Portrait 2024 guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/), [Portrait 2025 guide](https://www.portrait.com/resource-center/lg-2025-oled-and-qned-autocal-guide/), [Calibrating LG TVs with Calman](https://www.portrait.com/resource-center/calibrating-lg-tvs-with-calman/), [TFTCentral](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration):

| Step          | SDR (Cinema/Expert/Game/Filmmaker)                                         | HDR10 (HDR Cinema/Game/Filmmaker)                                                           | Dolby Vision (FILMMAKER/Cinema Home/Game)           |
| ------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| Source        | SDR, BT.709, video range                                                   | HDR10, BT.2020, ST 2084 (or HDMI override)                                                  | DV, **Relative** metadata                           |
| Reset         | Full DDC Reset = bypass                                                    | Reset                                                                                       | Reset                                               |
| Base controls | Brightness 50, Contrast 85, OLED light ≈ 15% above target                  | Brightness 50, Contrast 100, OLED light max                                                 | Brightness 50, Contrast 100                         |
| Greyscale     | 1D LUT AutoCal, "26pts SDR 16-255", target power 2.4 (dark) / 2.2 (bright) | 1D LUT AutoCal, "LG 20 Points HDR", target gamma 2.2 + D65 (HDR processing off in cal mode) | 1D LUT AutoCal, "LG 20 Points HDR", gamma 2.2 + D65 |
| Colour        | 3D LUT AutoCal (fixed grid / "Lighting LUT"), "3D LUT Grayscale to Unity"  | "Matrix LUT": 5 patches → 3×3 math → 3D LUT                                                 | DV config from W, K, R, G, B; upload                |
| Peak          | re-trim OLED light                                                         | measure 100% white (10% window) → Tone Curve Upload                                         | n/a                                                 |
| Finish        | uncheck Enable Calibration (= `CAL_END`, applies 3D LUT)                   | same                                                                                        | same; switch source to **Absolute** for validation  |
| Validate      | Rec.709 targets                                                            | Rec.2020/ST 2084                                                                            | P3/D65/ST 2084                                      |

Open-code mapping of these steps:

1. `setSystemSettings` picture mode + base settings; switch off AI/DTM/energy saving.
2. `CAL_START` (picMode) → bypass sequence (5.8) → `BRIGHTNESS_UI_DATA`/`CONTRAST_UI_DATA`/`BACKLIGHT_UI_DATA`.
3. Greyscale loop: measure N grey levels, build a 1024-point 1D LUT per channel, upload `1D_DPG_DATA` with `dataOpt:0` while iterating, `dataOpt:1` for the final upload (dataOpt semantics: [webos_client.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py)).
4. SDR colour: profile through the 1D-corrected path, build a 17³ LUT (B4), upload to `BT709_3D_LUT_DATA` (and `BT2020_3D_LUT_DATA` for BT.2020-flagged SDR).
5. HDR10: build a matrix-based 3D LUT for `BT2020_3D_LUT_DATA`; measure peak; upload `1D_TONEMAP_PARAM` with the peak and default roll-offs.
6. DV: measure W/K/R/G/B in relative mode; build the config (5.10); upload.
7. `CAL_END`; restore `colorGamut` if needed; verify.

---

## (a) Facts the implementer can rely on

1. Control socket: `wss://<ip>:3001`, TLS with LG's static self-signed chain; disable hostname checks; pin the LG fingerprints or pin on first use.
2. Frames are JSON `{id, type, uri, payload}`; the TV echoes `id`. Response types: `hello`, `response`, `registered`, `error`.
3. Registration: `type:"register"`, `id:"register_0"`, payload `{client-key, forcePairing:false, manifest, pairingType:"PROMPT"}`; prompt notice `{"pairingType":"PROMPT","returnValue":true}`; success `registered` with `client-key`.
4. webOS 26 rejects the signed `com.lge.test` manifest with `403 Pairing rejected: blacklisted certificate detected`; an unsigned manifest pairs with fewer rights.
5. SSDP search target `urn:lge-com:service:webos-second-screen:1`; the device description advertises serviceId `urn:lge-com:serviceId:webos-second-screen-3000-3001`.
6. MAC addresses come from `com.webos.service.connectionmanager/getinfo` (`wiredInfo.macAddress`, `wifiInfo.macAddress`); WoL is a 102-byte magic packet to UDP port 9 broadcast.
7. The B4 firmware token is `HE_DTV_W24H_AFADATAA`; chip `W24H` → 17-point 3D LUT and 2019-format DV config in bscpylgtv and PGenerator+.
8. externalpq payload fields: `command, picMode, profileNo:0, programID:1, data (base64 LE), dataCount (elements), dataType ("unsigned char"|"unsigned integer16"|"float"), dataOpt (0 apply, 1 apply+save, 2 reset)`.
9. 1D LUT: uint16 planar R/G/B × 1024, 0–32767. 3D LUT: uint16 N³×3, R fastest, 0–4095, `round(v*4096)` clipped. 3×3: float32 row-major. Flags/UI data: uint16 × 1. Tone map: uint16 × 7. The unity-LUT hashes in 5.3 match bscpylgtv's test fixtures.
10. Calibration only works between `CAL_START` and `CAL_END`, for a picMode that belongs to the signal class the TV currently shows.
11. Accepted picMode strings: `cinema, expert1, expert2, game, technicolorExpert, filmMaker, hdr_cinema, hdr_game, hdr_technicolorExpert, hdr_filmMaker, dolby_cinema_bright, dolby_cinema_dark, dolby_game`.
12. `CAL_START` forces Warm 50 and `colorGamut:"wide"`; HDR10 tone mapping is bypassed in calibration mode; HDR/DV greyscale targets gamma 2.2 + D65.
13. `externalpq/getExternalPqData` exists and returns `data/dataCount/dataType` for the six `GET_*` commands, with post-processed and sometimes broken data.
14. DV config modes: 1 = Cinema Home, 2 = Cinema/FILMMAKER, 4 = Game; `Tmax/Tmin/Tgamma/TPrimaries` (2019) or `PictureMode/Tmax/Tmin/Tgamma/ColorPrimaries/TLMS2RGBmat` (2018); CRLF.
15. Picture settings are stored per `[input, pictureMode]`; `pictureMode` per `[input, dynamicRange]`; writes without a dimension hit the current context.
16. The public `settings/setSystemSettings` takes only an allow-list of keys; other keys need the createAlert luna bridge, whose result is invisible and must be verified by reading back.
17. Calman's workflow: 10% window, B 50 / C 85 (SDR) or 100 (HDR/DV), DTM and energy saving off, 1D LUT then 3D LUT/matrix, tone curve from measured peak, DV config from W/K/R/G/B in relative mode.

## (b) UNCONFIRMED — verify on the B4

1. Current firmware family on the user's B4 (33.x webOS 25 vs 43.x webOS 26) and whether calibration works at all on it (EU factory-disabled SKUs).
2. Whether port 3000 is closed or rejects the upgrade on the B4.
3. hello `deviceOSVersion` value and full `pairingTypes` list on webOS 25.
4. Whether `getSystemInfo` must come before `register` on the B4.
5. Pairing prompt timeout and the exact error when it expires.
6. Which permission gates `externalpq` (`TEST_SECURE`? `TEST_PROTECTED`?).
7. `closeAlert` id form: raw `…apiadapter.pub-<n>` or rewritten `…apiadapter-<n>`.
8. Whether the luna bridge still works with manifest B on webOS 26.
9. Whether the SSAP `getSystemSettings` reply includes `dimension`, and whether `category:"dimensionInfo"` works.
10. Whether a dimension (category-string or object form) works through the luna bridge on webOS 25.
11. Exact UI labels for `brightness` ("Black Level"?) and the key for "Fine Tune Dark Areas".
12. Per-port values of `uhdDeepColorHDMIn` (`on` vs `4k`) and `444BypassHDMIn` meaning.
13. `CAL_START` form the B4 needs (no data vs 9 zero floats); whether `picMode` on every command is required or harmful.
14. 3D LUT size really 17 (probe `GET_3D_LUT_DATA` → `dataCount` 14739).
15. 3×3 matrix orientation; position of 3D LUT vs 1D LUT in the pipeline; input domain (64–1023 vs 0–1023).
16. Which `colorGamut` value selects the uploaded 3D LUT after `CAL_END`.
17. Whether calibration banks are global per picture mode or per input.
18. `1D_DPG_EN` and `3BY3_GAMUT_EN` effects on the B4.
19. Whether `game`, `hdr_game`, `dolby_game` accept uploads on current B4 firmware; whether DV Cinema Home/Game accept `CAL_START` or only DV FILMMAKER.
20. HLG: whether HLG content uses the `hdr_*` calibration.
21. DV config format accepted over `DOLBY_CFG_DATA` (2018-style vs bracketed 2019) and whether the B4 accepts the API path at all.
22. Tone-map parameter semantics in detail; interaction with DTM `on` and `HGIG`; meaning of `DtmMastering*`.
23. iTPG support on α8.
24. Pixel-refresh state visibility in `getPowerState` and the safe re-wake delay.
25. mDNS service types and TXT records.
26. `wolwowlOnOff` = "Turn on via Wi-Fi".

## (c) JSON fixtures for a fake TV server

Notes:

- Frames marked `"origin": "capture"` are copied from real-TV captures or observed-TV mocks (source in `_src`). Frames marked `"origin": "synthesized"` follow cited field lists with B4-plausible values.
- `{"$ref": "#/manifests/legacy_signed"}` means: substitute that object.
- `delay_ms` is a suggested server delay before sending the frame.
- base64 that is too long to inline is given as a generation rule plus SHA-256 of the decoded bytes (section 5.3).

```json
{
  "_meta": {
    "target": "LG OLED65B4PUA, webOS 25 (10.3.0), firmware 33.31.75",
    "doc": "docs/research/lg-webos.md"
  },
  "manifests": {
    "legacy_signed": {
      "appVersion": "1.1",
      "manifestVersion": 1,
      "deviceName": "bscpylgtv",
      "permissions": [
        "LAUNCH",
        "LAUNCH_WEBAPP",
        "APP_TO_APP",
        "CLOSE",
        "TEST_OPEN",
        "TEST_PROTECTED",
        "CONTROL_AUDIO",
        "CONTROL_DISPLAY",
        "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_RECORDING",
        "CONTROL_INPUT_MEDIA_PLAYBACK",
        "CONTROL_INPUT_TV",
        "CONTROL_POWER",
        "CONTROL_TV_SCREEN",
        "READ_APP_STATUS",
        "READ_CURRENT_CHANNEL",
        "READ_INPUT_DEVICE_LIST",
        "READ_NETWORK_STATE",
        "READ_RUNNING_APPS",
        "READ_TV_CHANNEL_LIST",
        "WRITE_NOTIFICATION_TOAST",
        "READ_POWER_STATE",
        "READ_COUNTRY_INFO",
        "CONTROL_INPUT_TEXT",
        "CONTROL_MOUSE_AND_KEYBOARD",
        "READ_INSTALLED_APPS",
        "READ_SETTINGS",
        "READ_STORAGE_DEVICE_LIST"
      ],
      "signatures": [
        {
          "signature": "eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw==",
          "signatureVersion": 1
        }
      ],
      "signed": {
        "appId": "com.lge.test",
        "created": "20140509",
        "localizedAppNames": {
          "": "LG Remote App",
          "ko-KR": "리모컨 앱",
          "zxx-XX": "ЛГ Rэмotэ AПП"
        },
        "localizedVendorNames": { "": "LG Electronics" },
        "permissions": [
          "TEST_SECURE",
          "CONTROL_INPUT_TEXT",
          "CONTROL_MOUSE_AND_KEYBOARD",
          "READ_INSTALLED_APPS",
          "READ_LGE_SDX",
          "READ_NOTIFICATIONS",
          "SEARCH",
          "WRITE_SETTINGS",
          "WRITE_NOTIFICATION_ALERT",
          "CONTROL_POWER",
          "READ_CURRENT_CHANNEL",
          "READ_RUNNING_APPS",
          "READ_UPDATE_INFO",
          "UPDATE_FROM_REMOTE_APP",
          "READ_LGE_TV_INPUT_EVENTS",
          "READ_TV_CURRENT_TIME"
        ],
        "serial": "2f930e2d2cfe083771f68e4fe7bb07",
        "vendorId": "com.lge"
      }
    },
    "generic_unsigned": {
      "appVersion": "1.1",
      "manifestVersion": 1,
      "permissions": [
        "APP_TO_APP",
        "CLOSE",
        "CONTROL_AUDIO",
        "CONTROL_DISPLAY",
        "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_PLAYBACK",
        "CONTROL_INPUT_MEDIA_RECORDING",
        "CONTROL_INPUT_TEXT",
        "CONTROL_INPUT_TV",
        "CONTROL_MOUSE_AND_KEYBOARD",
        "CONTROL_POWER",
        "CONTROL_TV_SCREEN",
        "LAUNCH",
        "LAUNCH_WEBAPP",
        "READ_APP_STATUS",
        "READ_COUNTRY_INFO",
        "READ_CURRENT_CHANNEL",
        "READ_INPUT_DEVICE_LIST",
        "READ_INSTALLED_APPS",
        "READ_LGE_SDX",
        "READ_LGE_TV_INPUT_EVENTS",
        "READ_NETWORK_STATE",
        "READ_NOTIFICATIONS",
        "READ_POWER_STATE",
        "READ_RUNNING_APPS",
        "READ_SETTINGS",
        "READ_TV_CHANNEL_LIST",
        "READ_TV_CURRENT_TIME",
        "READ_UPDATE_INFO",
        "SEARCH",
        "TEST_OPEN",
        "TEST_PROTECTED",
        "TEST_SECURE",
        "UPDATE_FROM_REMOTE_APP",
        "WRITE_NOTIFICATION_ALERT",
        "WRITE_NOTIFICATION_TOAST",
        "WRITE_SETTINGS"
      ]
    }
  },
  "handshake_first_pairing": [
    {
      "dir": "c2s",
      "frame": { "id": "hello", "type": "hello", "payload": {} }
    },
    {
      "dir": "s2c",
      "origin": "synthesized",
      "_src": "field list: HomeSeer LGRemote.vb capture; release 10.3.0 from chronomaly-webos#2",
      "frame": {
        "type": "hello",
        "id": "hello",
        "payload": {
          "protocolVersion": 1,
          "deviceType": "tv",
          "deviceOS": "webOS",
          "deviceOSVersion": "4.1.0",
          "deviceOSReleaseVersion": "10.3.0",
          "deviceUUID": "6da62662-1369-a82d-95c7-353c235ed503",
          "pairingTypes": ["PIN", "PROMPT", "COMBINED"]
        }
      }
    },
    {
      "dir": "c2s",
      "frame": {
        "id": "get_sys_info",
        "type": "request",
        "uri": "ssap://system/getSystemInfo",
        "payload": {}
      }
    },
    {
      "dir": "s2c",
      "origin": "synthesized",
      "_src": "fields: lgtv_manager ssap_payloads.rs",
      "frame": {
        "type": "response",
        "id": "get_sys_info",
        "payload": {
          "returnValue": true,
          "features": { "3d": false, "dvr": true },
          "receiverType": "atsc",
          "modelName": "OLED65B4PUA",
          "serialNumber": "406KPXX00000",
          "programMode": false
        }
      }
    },
    {
      "dir": "c2s",
      "frame": {
        "type": "register",
        "id": "register_0",
        "payload": {
          "client-key": null,
          "forcePairing": false,
          "manifest": { "$ref": "#/manifests/legacy_signed" },
          "pairingType": "PROMPT"
        }
      }
    },
    {
      "dir": "s2c",
      "origin": "capture",
      "_src": "lgtv2 mock-tv.js / LG_Buddy test_server.rs pairing_prompt_response",
      "frame": {
        "type": "response",
        "id": "register_0",
        "payload": { "pairingType": "PROMPT", "returnValue": true }
      }
    },
    {
      "dir": "s2c",
      "origin": "capture",
      "_src": "lgtv_manager RegisteredPayload; key value synthesized",
      "delay_ms": 3000,
      "frame": {
        "type": "registered",
        "id": "register_0",
        "payload": { "client-key": "8f3c2a71d9e04b6c95f1a2b3c4d5e6f7" }
      }
    }
  ],
  "handshake_stored_key": [
    {
      "dir": "c2s",
      "frame": {
        "type": "register",
        "id": "register_0",
        "payload": {
          "client-key": "8f3c2a71d9e04b6c95f1a2b3c4d5e6f7",
          "forcePairing": false,
          "manifest": { "$ref": "#/manifests/legacy_signed" },
          "pairingType": "PROMPT"
        }
      }
    },
    {
      "dir": "s2c",
      "frame": {
        "type": "registered",
        "id": "register_0",
        "payload": { "client-key": "8f3c2a71d9e04b6c95f1a2b3c4d5e6f7" }
      }
    }
  ],
  "handshake_user_declined": [
    {
      "dir": "s2c",
      "origin": "capture",
      "_src": "lgtv2 CHANGELOG 1.7.0 / mock-tv.js",
      "frame": {
        "type": "error",
        "id": "register_0",
        "error": "403 cancelled",
        "payload": {}
      }
    }
  ],
  "handshake_webos26_legacy_rejected": [
    {
      "dir": "c2s",
      "frame": {
        "type": "register",
        "id": "register_0",
        "payload": {
          "client-key": null,
          "forcePairing": false,
          "manifest": { "$ref": "#/manifests/legacy_signed" },
          "pairingType": "PROMPT"
        }
      }
    },
    {
      "dir": "s2c",
      "origin": "capture",
      "_src": "LG_Buddy test_server.rs (fw 43.21.60), lgtv2 mock-tv.js",
      "frame": {
        "type": "error",
        "id": "register_0",
        "error": "403 Pairing rejected: blacklisted certificate detected",
        "payload": {}
      }
    }
  ],
  "getSystemSettings_picture": {
    "request": {
      "id": 30,
      "type": "request",
      "uri": "ssap://settings/getSystemSettings",
      "payload": {
        "category": "picture",
        "keys": [
          "pictureMode",
          "backlight",
          "contrast",
          "brightness",
          "color",
          "tint",
          "sharpness",
          "colorGamut",
          "gamma",
          "colorTemperature",
          "dynamicContrast",
          "peakBrightness",
          "hdrDynamicToneMapping",
          "smoothGradation",
          "noiseReduction",
          "mpegNoiseReduction",
          "superResolution",
          "realCinema",
          "truMotionMode",
          "motionEyeCare",
          "energySaving",
          "dynamicColor",
          "blackLevel",
          "whiteBalanceMethod",
          "whiteBalancePoint",
          "whiteBalanceRedGain",
          "whiteBalanceGreenGain",
          "whiteBalanceBlueGain",
          "whiteBalanceRedOffset",
          "whiteBalanceGreenOffset",
          "whiteBalanceBlueOffset",
          "whiteBalanceIre",
          "whiteBalanceCodeValue",
          "whiteBalanceRed",
          "whiteBalanceGreen",
          "whiteBalanceBlue",
          "adjustingLuminance",
          "whiteBalanceLuminance"
        ]
      }
    },
    "response": {
      "origin": "synthesized",
      "_src": "envelope: LG_Buddy observed mock; values/types: bscpylgtv available_settings_G4.md",
      "frame": {
        "type": "response",
        "id": 30,
        "payload": {
          "category": "picture",
          "returnValue": true,
          "subscribed": false,
          "settings": {
            "pictureMode": "expert2",
            "backlight": "34",
            "contrast": "85",
            "brightness": "50",
            "color": "50",
            "tint": "0",
            "sharpness": "0",
            "colorGamut": "auto",
            "gamma": "high1",
            "colorTemperature": "50",
            "dynamicContrast": "off",
            "peakBrightness": "off",
            "hdrDynamicToneMapping": "on",
            "smoothGradation": "off",
            "noiseReduction": "off",
            "mpegNoiseReduction": "off",
            "superResolution": "off",
            "realCinema": "on",
            "truMotionMode": "off",
            "motionEyeCare": "off",
            "energySaving": "off",
            "dynamicColor": "off",
            "blackLevel": {
              "ntsc": "low",
              "ntsc443": "auto",
              "pal": "auto",
              "pal60": "auto",
              "palm": "low",
              "paln": "high",
              "secam": "auto",
              "unknown": "auto"
            },
            "whiteBalanceMethod": "2",
            "whiteBalancePoint": "high",
            "whiteBalanceRedGain": "0",
            "whiteBalanceGreenGain": "0",
            "whiteBalanceBlueGain": "0",
            "whiteBalanceRedOffset": "0",
            "whiteBalanceGreenOffset": "0",
            "whiteBalanceBlueOffset": "0",
            "whiteBalanceIre": "100",
            "whiteBalanceCodeValue": "21",
            "whiteBalanceRed": [
              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            ],
            "whiteBalanceGreen": [
              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            ],
            "whiteBalanceBlue": [
              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            ],
            "adjustingLuminance": [
              0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            ],
            "whiteBalanceLuminance": "130"
          }
        }
      }
    },
    "response_unknown_key": {
      "origin": "synthesized",
      "_src": "felixcool200 settings-plan.md (luna partial reply); SSAP form UNCONFIRMED",
      "frame": {
        "type": "response",
        "id": 31,
        "payload": {
          "category": "picture",
          "returnValue": false,
          "settings": { "backlight": "34" },
          "errorKey": ["hgig"]
        }
      }
    }
  },
  "setSystemSettings_public": {
    "request": {
      "id": 32,
      "type": "request",
      "uri": "ssap://settings/setSystemSettings",
      "payload": { "category": "picture", "settings": { "backlight": 34 } }
    },
    "response": {
      "origin": "capture",
      "_src": "LG_Buddy test_server.rs",
      "frame": {
        "type": "response",
        "id": 32,
        "payload": { "method": "setSystemSettings", "returnValue": true }
      }
    },
    "response_not_allowed": {
      "origin": "capture",
      "_src": "PGenerator-Plus #70 (webOS 26)",
      "frame": {
        "type": "error",
        "id": 33,
        "error": "500 Application error: Some keys are not allowed for the request",
        "payload": {}
      }
    }
  },
  "luna_bridge": [
    {
      "dir": "c2s",
      "frame": {
        "id": 21,
        "type": "request",
        "uri": "ssap://system.notifications/createAlert",
        "payload": {
          "message": " ",
          "buttons": [
            {
              "label": "",
              "onClick": "luna://com.webos.settingsservice/setSystemSettings",
              "params": {
                "category": "picture",
                "settings": { "backlight": "40" }
              }
            }
          ],
          "onclose": {
            "uri": "luna://com.webos.settingsservice/setSystemSettings",
            "params": {
              "category": "picture",
              "settings": { "backlight": "40" }
            }
          },
          "onfail": {
            "uri": "luna://com.webos.settingsservice/setSystemSettings",
            "params": {
              "category": "picture",
              "settings": { "backlight": "40" }
            }
          }
        }
      }
    },
    {
      "dir": "s2c",
      "origin": "capture",
      "_src": "LG_Buddy test_server.rs (webOS 24 9.2.2-61 model)",
      "frame": {
        "type": "response",
        "id": 21,
        "payload": {
          "returnValue": true,
          "alertId": "com.webos.service.apiadapter.pub-1786895965205"
        }
      }
    },
    {
      "dir": "c2s",
      "frame": {
        "id": 22,
        "type": "request",
        "uri": "ssap://system.notifications/closeAlert",
        "payload": { "alertId": "com.webos.service.apiadapter-1786895965205" }
      }
    },
    {
      "dir": "s2c",
      "frame": {
        "type": "response",
        "id": 22,
        "payload": { "returnValue": true }
      },
      "side_effect": { "picture.backlight": "40" }
    }
  ],
  "getExternalInputList": {
    "request": {
      "id": 10,
      "type": "request",
      "uri": "ssap://tv/getExternalInputList",
      "payload": {}
    },
    "response": {
      "origin": "synthesized",
      "_src": "shape: MatKlucznyk/LgWebOs dump + astelmach20/tv-home eim fixture",
      "frame": {
        "type": "response",
        "id": 10,
        "payload": {
          "returnValue": true,
          "devices": [
            {
              "id": "HDMI_1",
              "label": "HDMI 1",
              "port": 1,
              "connected": false,
              "appId": "com.webos.app.hdmi1",
              "icon": "http://192.168.1.50:3000/resources/0f2c55c1a2b3c4d5e6f708192a3b4c5d6e7f8091/HDMI_1.png",
              "modified": false,
              "lastUniqueId": -1,
              "hdmiPlugIn": false,
              "subList": [],
              "subCount": 0,
              "favorite": false
            },
            {
              "id": "HDMI_2",
              "label": "Calibration PG",
              "port": 2,
              "connected": true,
              "appId": "com.webos.app.hdmi2",
              "icon": "http://192.168.1.50:3000/resources/702fc51ab0b9369b631408241ba33f988576b6f3/settopbox.png",
              "modified": true,
              "lastUniqueId": 255,
              "hdmiPlugIn": true,
              "subList": [],
              "subCount": 0,
              "favorite": false
            },
            {
              "id": "HDMI_3",
              "label": "HDMI 3",
              "port": 3,
              "connected": false,
              "appId": "com.webos.app.hdmi3",
              "icon": "http://192.168.1.50:3000/resources/0beb52cda36f29fe5c35ce87fdd32489dfedfb9d/HDMI_3.png",
              "modified": false,
              "lastUniqueId": -1,
              "hdmiPlugIn": false,
              "subList": [],
              "subCount": 0,
              "favorite": false
            },
            {
              "id": "HDMI_4",
              "label": "HDMI 4",
              "port": 4,
              "connected": false,
              "appId": "com.webos.app.hdmi4",
              "icon": "http://192.168.1.50:3000/resources/1c9d0e7a2b4f6e8d0c1b3a5968778695a4b3c2d1/HDMI_4.png",
              "modified": false,
              "lastUniqueId": -1,
              "hdmiPlugIn": false,
              "subList": [],
              "subCount": 0,
              "favorite": false
            }
          ]
        }
      }
    }
  },
  "getSystemInfo": {
    "request": {
      "id": 11,
      "type": "request",
      "uri": "ssap://system/getSystemInfo",
      "payload": {}
    },
    "response": {
      "origin": "synthesized",
      "_src": "fields: lgtv_manager ssap_payloads.rs",
      "frame": {
        "type": "response",
        "id": 11,
        "payload": {
          "returnValue": true,
          "features": { "3d": false, "dvr": true },
          "receiverType": "atsc",
          "modelName": "OLED65B4PUA",
          "serialNumber": "406KPXX00000",
          "programMode": false
        }
      }
    }
  },
  "getCurrentSWInformation": {
    "request": {
      "id": 12,
      "type": "request",
      "uri": "ssap://com.webos.service.update/getCurrentSWInformation",
      "payload": {}
    },
    "response": {
      "origin": "synthesized",
      "_src": "shape: Samonac/cumulonimbus2000 capture (C2); model token: caniroot; version: LG US support",
      "frame": {
        "type": "response",
        "id": 12,
        "payload": {
          "returnValue": true,
          "product_name": "webOSTV 10.3",
          "model_name": "HE_DTV_W24H_AFADATAA",
          "sw_type": "FIRMWARE",
          "major_ver": "33",
          "minor_ver": "31.75",
          "country": "US",
          "country_group": "US",
          "device_id": "a8:23:fe:00:11:22",
          "auth_flag": "N",
          "ignore_disable": "N",
          "eco_info": "01",
          "config_key": "00",
          "language_code": "en-US"
        }
      }
    },
    "response_webos26_unsigned": {
      "origin": "capture",
      "_src": "aiowebostv PR #719",
      "frame": {
        "type": "error",
        "id": 12,
        "error": "401 insufficient permissions",
        "payload": {}
      }
    }
  },
  "misc": {
    "getinfo": {
      "request": {
        "id": 13,
        "type": "request",
        "uri": "ssap://com.webos.service.connectionmanager/getinfo",
        "payload": {}
      },
      "response": {
        "origin": "synthesized",
        "_src": "lgtv2 mock-tv.js",
        "frame": {
          "type": "response",
          "id": 13,
          "payload": {
            "returnValue": true,
            "subscribed": false,
            "wiredInfo": { "macAddress": "a8:23:fe:00:11:22" },
            "wifiInfo": { "macAddress": "a8:23:fe:00:11:23" }
          }
        }
      }
    },
    "getPowerState": {
      "request": {
        "id": 14,
        "type": "request",
        "uri": "ssap://com.webos.service.tvpower/power/getPowerState",
        "payload": {}
      },
      "response": {
        "origin": "synthesized",
        "_src": "lgtv2 mock-tv.js",
        "frame": {
          "type": "response",
          "id": 14,
          "payload": {
            "returnValue": true,
            "subscribed": false,
            "state": "Active",
            "processing": ""
          }
        }
      }
    },
    "getForegroundAppInfo": {
      "request": {
        "id": 15,
        "type": "request",
        "uri": "ssap://com.webos.applicationManager/getForegroundAppInfo",
        "payload": {}
      },
      "response": {
        "origin": "synthesized",
        "_src": "webosbrew luna.md / Hubitat driver",
        "frame": {
          "type": "response",
          "id": 15,
          "payload": {
            "returnValue": true,
            "appId": "com.webos.app.hdmi2",
            "windowId": "",
            "processId": ""
          }
        }
      }
    },
    "switchInput": {
      "request": {
        "id": 16,
        "type": "request",
        "uri": "ssap://tv/switchInput",
        "payload": { "inputId": "HDMI_2" }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 16,
          "payload": { "returnValue": true }
        }
      }
    },
    "unknownUri": {
      "request": {
        "id": 17,
        "type": "request",
        "uri": "ssap://foo/bar",
        "payload": {}
      },
      "response": {
        "origin": "capture",
        "_src": "bscpylgtv request()",
        "frame": {
          "type": "error",
          "id": 17,
          "error": "404 no such service or method",
          "payload": {}
        }
      }
    }
  },
  "externalpq": [
    {
      "name": "CAL_START (bscpylgtv form)",
      "request": {
        "id": 40,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "CAL_START",
          "profileNo": 0,
          "programID": 1,
          "picMode": "expert2"
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 40,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "CAL_START (Calman form)",
      "request": {
        "id": 41,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "CAL_START",
          "picMode": "expert2",
          "profileNo": 0,
          "programID": 1,
          "data": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "dataCount": 9,
          "dataType": "float",
          "dataOpt": 1
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 41,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "BACKLIGHT_UI_DATA 39",
      "request": {
        "id": 42,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "BACKLIGHT_UI_DATA",
          "picMode": "expert2",
          "profileNo": 0,
          "programID": 1,
          "data": "JwA=",
          "dataCount": 1,
          "dataType": "unsigned integer16",
          "dataOpt": 1
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 42,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "1D_2_2_EN off",
      "request": {
        "id": 43,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "1D_2_2_EN",
          "picMode": "expert2",
          "profileNo": 0,
          "programID": 1,
          "data": "AAA=",
          "dataCount": 1,
          "dataType": "unsigned integer16",
          "dataOpt": 1
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 43,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "BT709_3BY3_GAMUT_DATA identity",
      "request": {
        "id": 44,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "BT709_3BY3_GAMUT_DATA",
          "picMode": "expert2",
          "profileNo": 0,
          "programID": 1,
          "data": "AACAPwAAAAAAAAAAAAAAAAAAgD8AAAAAAAAAAAAAAAAAAIA/",
          "dataCount": 9,
          "dataType": "float",
          "dataOpt": 1
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 44,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "BT709_3D_LUT_DATA unity 17pt",
      "request": {
        "id": 45,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "BT709_3D_LUT_DATA",
          "picMode": "expert2",
          "profileNo": 0,
          "programID": 1,
          "data": {
            "$gen": "unity_3d_lut",
            "n": 17,
            "decoded_bytes": 29478,
            "base64_length": 39304,
            "sha256": "7bf3000f247f76254a920e17b1ed23e6e12edacfbf493c99f7527e5f9b3e44ab"
          },
          "dataCount": 14739,
          "dataType": "unsigned integer16",
          "dataOpt": 1
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 45,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "1D_DPG_DATA unity (bscpylgtv)",
      "request": {
        "id": 46,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "1D_DPG_DATA",
          "picMode": "expert2",
          "profileNo": 0,
          "programID": 1,
          "data": {
            "$gen": "unity_1d_lut_linspace",
            "decoded_bytes": 6144,
            "base64_length": 8192,
            "sha256": "51a5362cea91bfcea487c7160c249f3ae0380fc4d3028b6c0b5036dfafa0dd80"
          },
          "dataCount": 3072,
          "dataType": "unsigned integer16",
          "dataOpt": 1
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 46,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "1D_DPG_DATA factory reset",
      "request": {
        "id": 47,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "1D_DPG_DATA",
          "picMode": "expert2",
          "profileNo": 0,
          "programID": 1,
          "data": "",
          "dataCount": 0,
          "dataType": "unsigned integer16",
          "dataOpt": 2
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 47,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "CAL_END",
      "request": {
        "id": 48,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "CAL_END",
          "profileNo": 0,
          "programID": 1,
          "picMode": "expert2"
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 48,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "1D_TONEMAP_PARAM hdr_cinema 760",
      "request": {
        "id": 49,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "1D_TONEMAP_PARAM",
          "picMode": "hdr_cinema",
          "profileNo": 0,
          "programID": 1,
          "data": "+ALoA0sAoA88ABAnMgA=",
          "dataCount": 7,
          "dataType": "unsigned integer16",
          "dataOpt": 1
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 49,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "DOLBY_CFG_DATA 2019 format, Game 820 nits",
      "_src": "bscpylgtv tests (W22O)",
      "request": {
        "id": 50,
        "type": "request",
        "uri": "ssap://externalpq/setExternalPqData",
        "payload": {
          "command": "DOLBY_CFG_DATA",
          "picMode": "dolby_game",
          "profileNo": 0,
          "programID": 1,
          "data": "W1BpY3R1cmVNb2RlID0gNF0NClRtYXggPSA4MjAuMDAwMA0KVG1pbiA9IDAuMDAwMQ0KVGdhbW1hID0gMi4yDQpUUHJpbWFyaWVzID0gMC42Nzk2IDAuMzE4NyAwLjI1OTUgMC42ODQ5IDAuMTQ0OCAwLjA0OTQgMC4zMTI3IDAuMzI5MA0K",
          "dataCount": 135,
          "dataType": "unsigned char",
          "dataOpt": 1
        }
      },
      "response": {
        "frame": {
          "type": "response",
          "id": 50,
          "payload": { "returnValue": true }
        }
      }
    },
    {
      "name": "GET_1D_2_2_EN",
      "request": {
        "id": 51,
        "type": "request",
        "uri": "ssap://externalpq/getExternalPqData",
        "payload": { "command": "GET_1D_2_2_EN" }
      },
      "response": {
        "origin": "capture",
        "_src": "bscpylgtv tests",
        "frame": {
          "type": "response",
          "id": 51,
          "payload": {
            "returnValue": true,
            "data": "AAA=",
            "dataCount": 1,
            "dataType": "unsigned integer16"
          }
        }
      }
    },
    {
      "name": "GET_3BY3_GAMUT_DATA",
      "request": {
        "id": 52,
        "type": "request",
        "uri": "ssap://externalpq/getExternalPqData",
        "payload": { "command": "GET_3BY3_GAMUT_DATA" }
      },
      "response": {
        "origin": "capture",
        "_src": "bscpylgtv tests: [[0.4,0.3,0.2],[0.2,0.4,0.3],[0.3,0.2,0.4]]",
        "frame": {
          "type": "response",
          "id": 52,
          "payload": {
            "returnValue": true,
            "data": "zczMPpqZmT7NzEw+zcxMPs3MzD6amZk+mpmZPs3MTD7NzMw+",
            "dataCount": 9,
            "dataType": "float"
          }
        }
      }
    },
    {
      "name": "getExternalPqData without data",
      "response": {
        "origin": "capture",
        "_src": "aiopylgtv #44",
        "frame": {
          "type": "error",
          "id": 53,
          "error": "500 Application error",
          "payload": {
            "returnValue": false,
            "errorText": "no file path from tvservice"
          }
        }
      }
    },
    {
      "name": "driver error 20",
      "response": {
        "origin": "capture",
        "_src": "PGenerator-Plus tests",
        "frame": {
          "type": "error",
          "id": 54,
          "error": "500 Application error",
          "payload": {
            "returnValue": false,
            "errorCode": 20,
            "errorMessage": "Driver error while executing the command"
          }
        }
      }
    },
    {
      "name": "webOS 26 CAL_START",
      "response": {
        "origin": "capture",
        "_src": "PGenerator-Plus #70/#71",
        "frame": {
          "type": "error",
          "id": 55,
          "error": "401 insufficient permissions",
          "payload": {}
        }
      }
    }
  ],
  "generators": {
    "unity_1d_lut_linspace": "for ch in 0..<3 { for i in 0..<1024 { u16le(round(i*32767/1023)) } }",
    "unity_1d_lut_calman": "for ch in 0..<3 { for i in 0..<1024 { u16le(i*32) } }  // sha256 351e9a3ca08b509767a04ad8080300980f97b63580804549cfbe8c7e50681af6",
    "unity_3d_lut": "for b in 0..<n { for g in 0..<n { for r in 0..<n { for v in [r,g,b] { u16le(min(round(v*4096/(n-1)),4095)) } } } }"
  }
}
```

Fake-server behaviour to model (from the sources above):

- Hold a picture store keyed by `[input, pictureMode]` and a mode store keyed by `[input, dynamicRange]`.
- Reject externalpq commands outside `CAL_START`…`CAL_END` and for a picMode outside the current signal class (error 20 shape).
- Validate `dataCount` against decoded length and `dataType` (uint16 = 2 bytes, float = 4, uint8 = 1); validate ranges (1D ≤ 32767, 3D ≤ 4095, 3×3 within ±1024).
- On `CAL_START` set `colorTemperature:"50"` and `colorGamut:"wide"`.
- Make `getExternalPqData` return what was last uploaded for the active picMode.
- Add a "webOS 26" profile: signed manifest → `403 … blacklisted`; `CAL_START`, `setSystemSettings`, `getCurrentSWInformation` → `401`.

## (d) Sources

Code and repositories (cloned and read 2026-10-31):

- bscpylgtv (v0.5.5, commit 191e895, 2026-09-30): https://github.com/chros73/bscpylgtv — [webos_client.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/webos_client.py), [cal_commands.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/cal_commands.py), [constants.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/constants.py), [endpoints.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/endpoints.py), [manifest.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/manifest.py), [lut_tools.py](https://github.com/chros73/bscpylgtv/blob/master/bscpylgtv/lut_tools.py), [README](https://github.com/chros73/bscpylgtv/blob/master/README.md), [CHANGELOG](https://github.com/chros73/bscpylgtv/blob/master/CHANGELOG.md), [LICENSE.txt](https://github.com/chros73/bscpylgtv/blob/master/LICENSE.txt), [available_settings_G4.md](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G4.md), [G5](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G5.md), [G6](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_G6.md), [C2](https://github.com/chros73/bscpylgtv/blob/master/docs/available_settings_C2.md), [guides](https://github.com/chros73/bscpylgtv/tree/master/docs/guides), [manifests](https://github.com/chros73/bscpylgtv/blob/master/docs/manifests/README.md), [scripts](https://github.com/chros73/bscpylgtv/tree/master/docs/scripts), [tests](https://github.com/chros73/bscpylgtv/tree/master/tests). The repository has no wiki (clone of `bscpylgtv.wiki.git` fails) and issues are disabled.
- aiopylgtv: https://github.com/bendavid/aiopylgtv — [webos_client.py](https://github.com/bendavid/aiopylgtv/blob/master/aiopylgtv/webos_client.py), [constants.py](https://github.com/bendavid/aiopylgtv/blob/master/aiopylgtv/constants.py), [handshake.py](https://github.com/bendavid/aiopylgtv/blob/master/aiopylgtv/handshake.py), [issue #44](https://github.com/bendavid/aiopylgtv/issues/44)
- lgtv2 (2.1.0): https://github.com/hobbyquaker/lgtv2 — [index.js](https://github.com/hobbyquaker/lgtv2/blob/master/index.js), [README](https://github.com/hobbyquaker/lgtv2/blob/master/README.md), [CHANGELOG](https://github.com/hobbyquaker/lgtv2/blob/master/CHANGELOG.md), [test/mock-tv.js](https://github.com/hobbyquaker/lgtv2/blob/master/test/mock-tv.js)
- aiowebostv (0.10.0): https://github.com/home-assistant-libs/aiowebostv — [handshake.py](https://github.com/home-assistant-libs/aiowebostv/blob/main/aiowebostv/handshake.py), [webos_client.py](https://github.com/home-assistant-libs/aiowebostv/blob/main/aiowebostv/webos_client.py), [PR #719](https://github.com/home-assistant-libs/aiowebostv/pull/719)
- PGenerator-Plus: https://github.com/oldgithubman/PGenerator-Plus — [usr/sbin/pgenerator-lg](https://github.com/oldgithubman/PGenerator-Plus/blob/main/usr/sbin/pgenerator-lg), [tv/lg capability library](https://github.com/oldgithubman/PGenerator-Plus/tree/main/usr/share/PGenerator/tv/lg), [tests](https://github.com/oldgithubman/PGenerator-Plus/tree/main/t), [issue #68](https://github.com/oldgithubman/PGenerator-Plus/issues/68), [#70](https://github.com/oldgithubman/PGenerator-Plus/issues/70), [#71](https://github.com/oldgithubman/PGenerator-Plus/issues/71)
- LG_Buddy: [test_server.rs](https://github.com/Staphylococcus/LG_Buddy/blob/main/crates/lg-buddy/src/web_os/test_support/test_server.rs), [picture.rs](https://github.com/Staphylococcus/LG_Buddy/blob/main/crates/lg-buddy/src/web_os/picture.rs)
- ColorControl: [LgTvApi.cs](https://github.com/Maassoft/ColorControl/blob/master/ColorControl/lgtv/LgTvApi.cs)
- webosbrew caniroot: [models.gen.js](https://github.com/webosbrew/caniroot/blob/main/src/models.gen.js), [mappings.js](https://github.com/webosbrew/caniroot/blob/main/tools/mappings.js)
- LG Connect SDK: [WebOSTVServiceSocketClient.java](https://github.com/ConnectSDK/Connect-SDK-Android-Core/blob/master/src/com/connectsdk/service/webos/WebOSTVServiceSocketClient.java), [webOS device description sample](https://github.com/ConnectSDK/Connect-SDK-iOS-Core/blob/master/ConnectSDKTests/Discovery/Providers/sample_data/webos/ssdp_device_description_webos_minor_webos.xml)
- lgtv_manager: [ssap_payloads.rs](https://github.com/mjoblin/lgtv_manager/blob/main/src/ssap_payloads.rs)
- Open webOS connman adapter: [connectionmanager_service.c](https://github.com/openwebos/webos-connman-adapter/blob/master/src/connectionmanager_service.c)
- webOS OSE settingsservice: [PrefsKeyDescMap.cpp](https://github.com/webosose/settingsservice/blob/master/Src/PrefsKeyDescMap.cpp)
- felixcool200 webOS-apps: [settings-plan.md](https://github.com/felixcool200/webOS-apps/blob/main/docs/settings-plan.md)
- plx-native: [dolby-vision.md](https://github.com/GLinnik21/plx-native/blob/main/docs/dolby-vision.md)
- Real response dumps: [MatKlucznyk/LgWebOs commands](https://github.com/MatKlucznyk/LgWebOs/blob/master/WebSocket%20Requests/commands), [astelmach20/tv-home eim fixture](https://github.com/astelmach20/tv-home/blob/main/server/test/fixtures/eim-appletv-on.json), [Samonac/cumulonimbus2000 control_tv.py](https://github.com/Samonac/cumulonimbus2000/blob/main/control_tv.py), [HomeSeer LGRemote.vb](https://github.com/dcorsus/HomeSeer-MediaController/blob/master/LGRemote.vb), [Hubitat LG driver](https://github.com/syepes/Hubitat/blob/master/Drivers/LG/LG%20WebOS%20TV.groovy)
- Discovery: [LGWebOSRemote scan.py](https://github.com/klattimer/LGWebOSRemote/blob/master/LGTV/scan.py), [BrokeMyLGRemote discover.ts](https://github.com/mengkeat/BrokeMyLGRemote/blob/main/discover/discover.ts), [jcarbaugh gist](https://gist.github.com/jcarbaugh/e08dcfe61ece0e7eea12), [UMS LG-L-2022+.conf](https://github.com/UniversalMediaServer/UniversalMediaServer/blob/main/src/main/external-resources/renderers/LG-L-2022+.conf), [UMS LG-TV-2023+.conf](https://github.com/UniversalMediaServer/UniversalMediaServer/blob/main/src/main/external-resources/renderers/LG-TV-2023+.conf), [openHAB community capture](https://community.openhab.org/t/connect-sdk-binding-for-lg-webos-tvs/4726?page=4)
- Version mapping: [omp installPlan.ts](https://github.com/spacesarmat/omp/blob/main/src/lib/installPlan.ts), [chronomaly-webos #2](https://github.com/AnalyticETH/chronomaly-webos/issues/2)
- webOS 26 pairing: [HA core #172703](https://github.com/home-assistant/core/issues/172703), [LGTVCompanion #351](https://github.com/JPersson77/LGTVCompanion/issues/351), [Orishas webostv-webos26-fix](https://github.com/Orishas/webostv-webos26-fix)

Home Assistant:

- [webostv integration docs](https://www.home-assistant.io/integrations/webostv/), [manifest.json](https://github.com/home-assistant/core/blob/dev/homeassistant/components/webostv/manifest.json), [config_flow.py](https://github.com/home-assistant/core/blob/dev/homeassistant/components/webostv/config_flow.py), [generated ssdp.py](https://github.com/home-assistant/core/blob/dev/homeassistant/generated/ssdp.py)

Calibration practice:

- Portrait Displays: [Calibrating LG TVs with Calman](https://www.portrait.com/resource-center/calibrating-lg-tvs-with-calman/), [LG 2024 OLED and QNED AutoCal Guide](https://www.portrait.com/resource-center/2024-lg-autocal-guide/), [LG 2025 OLED and QNED AutoCal Guide](https://www.portrait.com/resource-center/lg-2025-oled-and-qned-autocal-guide/)
- [TFTCentral LG OLED calibration guide](https://tftcentral.co.uk/guides/lg-oled-tv-calibration-guide-autocal-and-hardware-calibration)
- Light Illusion forum: [LG OLED Profiling/Calibration Guides](https://lightillusion.com/forums/display-calibration-8/lg-oled-profiling-calibration-guides-775.html), [LG interaction latest release webOS](https://lightillusion.com/forums/display-calibration-8/lg-interaction-latest-release-webos-1001.html)
- AVS Forum: [LG OLED EU TVs 2024/2025 Calibration Capability Database](https://www.avsforum.com/threads/lg-oled-eu-tvs-2024-2025-calibration-capability-database.3330101/) (read via search snippets; the site blocked direct fetching)
- doom9: [bscpylgtv thread](https://forum.doom9.org/showthread.php?t=175007)
- [displaycalibrations.com LG OLED signal chain diagram](https://displaycalibrations.com/images/LG_OLED_Video_Signal_Chain_Diagram_Picture.png)

News and LG pages:

- [TechTimes: webOS 26 calibration tools not included](https://www.techtimes.com/articles/325552/20260825/free-webos-26-update-hits-older-lg-tvs-calibration-tools-not-included.htm), [FlatpanelsHD: webOS 26 rollout](https://flatpanelshd.com/news.php?id=1787298592&subaction=showfull), [Cachy's Blog](https://stadt-bremerhaven.de/lg-oled-2025-webos-26-ist-da/), [Pocket-lint](https://www.pocket-lint.com/lg-tvs-webos-26-update-rollout/)
- [Notebookcheck: B4 with webOS 24 and α8](https://www.notebookcheck.net/New-LG-OLED-TV-line-with-webOS-24-and-Dolby-Vision-released-to-US-market.849145.0.html), [Engadget: LG AirPlay 2/HomeKit 2019](https://www.engadget.com/2019-01-07-lg-airplay-2-homekit-apple.html)
- LG support: [OLED48B4PUA](https://www.lg.com/us/support/product/lg-OLED48B4PUA.AUS), [OLED65B4PUA](https://www.lg.com/us/support/product/lg-OLED65B4PUA.AUS), [TV On with Mobile](https://www.lg.com/uk/support/product-support/troubleshoot/help-library/cs-CT00008333-20153442360449LST/), [automatic pixel cleaning](https://www.lg.com/ae/support/product-help/CT20076005-20153292130516OLT), [Game Optimizer](https://www.lg.com/us/support/help-library/lg-tv-how-to-use-the-game-optimizer-CT10000018-20153207342504), [picture modes](https://www.lg.com/lk/support/product-help/CT30012353-1436494367250)
- [BGR: OLED pixel cleaning](https://bgr.com/2098397/how-often-oled-displays-need-pixel-cleaning/)

Not used: the LG webOS TV developer site documents app-side luna APIs, not SSAP or externalpq. No official LG document for either was found.
