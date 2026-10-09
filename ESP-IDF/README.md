# InkDesk E1001 — ESP-IDF

Native ESP-IDF companion firmware for the Seeed reTerminal E1001 (ESP32-S3 / UC8179 / 800×480 monochrome).

This directory contains source, configurable hardware settings and host protocol tests. Build a firmware image for your own board and network; generated images in `firmware/` are excluded from the source repository. The project was built with ESP-IDF v6.0.1. Install its tools using the [ESP32-S3 setup guide](https://docs.espressif.com/projects/esp-idf/en/v6.0.1/esp32s3/get-started/index.html), then activate your installation's environment.

```sh
source /path/to/esp-idf/export.sh
cd /path/to/InkDesk/ESP-IDF
idf.py set-target esp32s3
```

Connect the E1001 with a data-capable USB cable, turn its power switch on, and identify its serial port. Substitute that port for `PORT` in the commands below. Detect the board's chip and Flash capacity with [esptool](https://docs.espressif.com/projects/esptool/en/latest/esp32s3/esptool/basic-commands.html):

```sh
python -m esptool --chip esp32s3 --port PORT flash-id
```

The source defaults select **8 MB Flash**, DIO at 80 MHz and octal PSRAM at 80 MHz. An E1001 with **32 MB Flash** needs the 32 MB setting under **Serial flasher config → Flash size** before building. Select the detected capacity for your board. Display pins, button pins, SPI speed and the BUSY timeout are configurable under **InkDesk E1001**; check them against your board revision.

Open InkDesk on the Mac and start its synchronization service in the **Devices** screen. Keep the Mac and E1001 on a network that allows them to reach each other. Run:

```sh
idf.py menuconfig
```

Under **InkDesk E1001**, set:

- The 2.4 GHz Wi-Fi SSID and password.
- The Mac server origin, using the Mac's actual LAN address and service port, normally `http://LAN-IP:8765`, without a trailing slash. The `http://127.0.0.1:8765` default is an unconfigured placeholder: on the ESP32 it refers to the device itself.
- The device pairing token copied from InkDesk's Devices screen. This is separate from an AI API key; no AI key belongs in the firmware.

SSID, password and device token default to empty strings. Configuration is embedded in the compiled image, so changing the network, Mac address or token requires rebuilding and flashing. Keep your generated `sdkconfig`, build directory and configured images private.

```sh
idf.py build
./tests/run_host_tests.sh
idf.py -p PORT flash monitor
```

The first full flash writes the bootloader, partition table, application and an empty SPIFFS cache image generated from `cache_seed/`. For later application updates with an unchanged partition layout, use `idf.py -p PORT app-flash monitor` to preserve the cache and NVS. Exit the monitor with `Ctrl-]`.

On startup, the serial log should report Wi-Fi connection, an IP address and acceptance of a verified frame. If association fails, check the SSID, password, 2.4 GHz availability and power. If Wi-Fi connects but no frame arrives, check the Mac service, LAN address, port, device token and network reachability. If the panel reports a BUSY timeout, check the display settings and board wiring. More configuration and button controls are described in [the firmware guide](../docs/firmware.md).

The firmware claims an immutable frame from `/api/sync/manifest`, verifies all 48,000 raw monochrome bytes with SHA-256, and reports downloaded/refreshing/displayed/failed through `/api/sync/status`. A successful panel refresh confirms display; identical pixels already displayed during this boot can be acknowledged without another refresh. A separate NVS status journal retries lost receipts, while cached bytes alone never supply display proof after reboot. Verified snapshots and immutable event UUIDs persist for offline task actions. This version stays awake and uses full BW refreshes; battery operation needs further power work.

The display command sequence and pin mapping are adapted from [Seeed_GFX commit 0dfdd7135425be82b5bb4b4b58d74dd51ab29a59](https://github.com/Seeed-Studio/Seeed_GFX/tree/0dfdd7135425be82b5bb4b4b58d74dd51ab29a59); its upstream notices are retained in [NOTICE-Seeed-GFX.txt](NOTICE-Seeed-GFX.txt). [cJSON v1.7.19](https://github.com/DaveGamble/cJSON/tree/v1.7.19) is vendored unchanged under [its MIT license](main/vendor/LICENSE.cJSON). ESP-IDF is an external build dependency with its own component licenses.
