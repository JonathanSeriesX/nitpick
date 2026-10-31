import Foundation

/// SSAP registration manifests (SPEC §3.4).
///
/// Manifest A is copied verbatim from bscpylgtv `manifest.py`, under this licence:
///
///     MIT License. Copyright (c) 2017 Dennis Karpienski, Copyright (c) 2019 Josh Bendavid.
///     Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
///     documentation files (the "Software"), to deal in the Software without restriction, including without limitation
///     the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
///     to permit persons to whom the Software is furnished to do so, subject to the following conditions:
///     The above copyright notice and this permission notice shall be included in all copies or substantial portions of
///     the Software.
///     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
///     THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
///     AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
///     CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
///     IN THE SOFTWARE.
///
/// The `signature` inside it belongs to LG (from LG's own remote app); webOS 26 blacklists it.
/// Manifest B is the generic unsigned manifest from aiowebostv `handshake.py` (Apache-2.0, Home Assistant).
public enum SSAPManifests {
    /// Manifest A: signed `com.lge.test` (webOS ≤ 25; needed for calibration, settings writes and the luna bridge).
    public static let signedLegacy: JSON = try! JSON.decode(signedLegacyText)
    /// Manifest B: unsigned fallback (webOS 26).
    public static let unsigned: JSON = try! JSON.decode(unsignedText)

    public static func manifest(_ kind: SSAPManifestKind) -> JSON { kind == .signedLegacy ? signedLegacy : unsigned }

    static let signedLegacyText = #"""
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
        """#

    static let unsignedText = #"""
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
        """#
}
