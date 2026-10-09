# Third-party notices

InkDesk's original source is distributed under the [MIT License](LICENSE).
The following components retain their upstream notices and licenses.

| Component | Usage | Upstream and license notice |
| --- | --- | --- |
| cJSON 1.7.19 | Vendored JSON parser for the ESP-IDF firmware | [Upstream](https://github.com/DaveGamble/cJSON/tree/v1.7.19), [MIT notice](ESP-IDF/main/vendor/LICENSE.cJSON) |
| Seeed_GFX | Reference for the E1001 pinout and UC8179 display command sequence; adapted in `ESP-IDF/main/epd.c` | [Pinned source](https://github.com/Seeed-Studio/Seeed_GFX/tree/0dfdd7135425be82b5bb4b4b58d74dd51ab29a59), [retained upstream notice](ESP-IDF/NOTICE-Seeed-GFX.txt) |

The Seeed notice includes the upstream Adafruit and Bodmer license and
attribution text. These notices must remain with redistributed derivatives.

ESP-IDF is an external build dependency, and its SDK components retain their
own licenses. This repository publishes firmware source, rather than SDK-linked
firmware binaries. If you distribute a built firmware image, include the licenses
and notices required by the SDK components included in that build.

The app icon was generated with ImageGen. Its source image and generation prompt
are included in `Assets/`; it does not use the Seeed or Apple logos.
