import Foundation

/// Server frames for `FakeWebOSServer`, copied from the JSON fixtures of docs/research/lg-webos.md §(c)
/// (captures and synthesized B4 frames; the server replaces `id` and patches version fields per platform).
enum FakeWebOSFixtures {
    static let frames: [String: JSON] = try! JSON.decode(text).objectValue!

    static func frame(_ name: String) -> JSON { frames[name]! }
    static func payload(_ name: String) -> [String: JSON] { frames[name]!["payload"]!.objectValue! }

    private static let text = #"""
        {
          "hello": {
            "type": "hello",
            "id": "hello",
            "payload": {
              "protocolVersion": 1,
              "deviceType": "tv",
              "deviceOS": "webOS",
              "deviceOSVersion": "4.1.0",
              "deviceOSReleaseVersion": "10.3.0",
              "deviceUUID": "6da62662-1369-a82d-95c7-353c235ed503",
              "pairingTypes": [
                "PIN",
                "PROMPT",
                "COMBINED"
              ]
            }
          },
          "getSystemInfo": {
            "type": "response",
            "id": 11,
            "payload": {
              "returnValue": true,
              "features": {
                "3d": false,
                "dvr": true
              },
              "receiverType": "atsc",
              "modelName": "OLED65B4PUA",
              "serialNumber": "406KPXX00000",
              "programMode": false
            }
          },
          "registerPrompt": {
            "type": "response",
            "id": "register_0",
            "payload": {
              "pairingType": "PROMPT",
              "returnValue": true
            }
          },
          "registered": {
            "type": "registered",
            "id": "register_0",
            "payload": {
              "client-key": "8f3c2a71d9e04b6c95f1a2b3c4d5e6f7"
            }
          },
          "registerDeclined": {
            "type": "error",
            "id": "register_0",
            "error": "403 cancelled",
            "payload": {}
          },
          "registerBlacklisted": {
            "type": "error",
            "id": "register_0",
            "error": "403 Pairing rejected: blacklisted certificate detected",
            "payload": {}
          },
          "getCurrentSWInformation": {
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
          },
          "insufficientPermissions": {
            "type": "error",
            "id": 12,
            "error": "401 insufficient permissions",
            "payload": {}
          },
          "getExternalInputList": {
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
          },
          "getSystemSettingsPicture": {
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
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0
                ],
                "whiteBalanceGreen": [
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0
                ],
                "whiteBalanceBlue": [
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0
                ],
                "adjustingLuminance": [
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0,
                  0
                ],
                "whiteBalanceLuminance": "130"
              }
            }
          },
          "getSystemSettingsUnknownKey": {
            "type": "response",
            "id": 31,
            "payload": {
              "category": "picture",
              "returnValue": false,
              "settings": {
                "backlight": "34"
              },
              "errorKey": [
                "hgig"
              ]
            }
          },
          "setSystemSettings": {
            "type": "response",
            "id": 32,
            "payload": {
              "method": "setSystemSettings",
              "returnValue": true
            }
          },
          "setSystemSettingsNotAllowed": {
            "type": "error",
            "id": 33,
            "error": "500 Application error: Some keys are not allowed for the request",
            "payload": {}
          },
          "createAlert": {
            "type": "response",
            "id": 21,
            "payload": {
              "returnValue": true,
              "alertId": "com.webos.service.apiadapter.pub-1786895965205"
            }
          },
          "getinfo": {
            "type": "response",
            "id": 13,
            "payload": {
              "returnValue": true,
              "subscribed": false,
              "wiredInfo": {
                "macAddress": "a8:23:fe:00:11:22"
              },
              "wifiInfo": {
                "macAddress": "a8:23:fe:00:11:23"
              }
            }
          },
          "getPowerState": {
            "type": "response",
            "id": 14,
            "payload": {
              "returnValue": true,
              "subscribed": false,
              "state": "Active",
              "processing": ""
            }
          },
          "getForegroundAppInfo": {
            "type": "response",
            "id": 15,
            "payload": {
              "returnValue": true,
              "appId": "com.webos.app.hdmi2",
              "windowId": "",
              "processId": ""
            }
          },
          "unknownURI": {
            "type": "error",
            "id": 17,
            "error": "404 no such service or method",
            "payload": {}
          },
          "externalPQSuccess": {
            "type": "response",
            "id": 40,
            "payload": {
              "returnValue": true
            }
          },
          "externalPQNoData": {
            "type": "error",
            "id": 53,
            "error": "500 Application error",
            "payload": {
              "returnValue": false,
              "errorText": "no file path from tvservice"
            }
          },
          "externalPQDriverError": {
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
        """#
}
