# BirdMenu

BirdMenu is a macOS menu bar app for compatible Bluetooth Low Energy thermometer/hygrometer sensors.

It listens for the device's BLE advertisements and shows the communication state, temperature, and humidity in the menu bar. The detail menu also shows battery level, RSSI, and the last update time.

When multiple compatible sensors are detected, BirdMenu keeps the latest reading for each device. The menu bar shows the average temperature and humidity by default, and the menu lets you switch the display to a specific sensor.

Compatibility testing has been performed with the INKBIRD ITH-11-B sensor. BirdMenu is an independent utility and is not affiliated with or endorsed by INKBIRD.

![BirdMenu screenshot](images/birdmenu.png)

## History Fetch

The menu includes `Fetch Sensor History`. It connects to the selected compatible sensor using one of two observed history protocols.

For tested ITH-11-B units exposing `fff3`, `fff4`, `fff5`, `fff6`, and `fff7`, BirdMenu:

- reads the recording interval from `fff5` and subscribes to `fff6`
- sets the session clock through `fff7`, then requests metadata and history through `fff4`
- validates and deduplicates history blocks, requesting missing or invalid blocks through `fff3` and `fff4`
- saves the complete raw history and CSV **before** sending the completion/session-close commands

For compatible devices exposing `fff8`, BirdMenu uses the history-read command pattern observed from related BLE hygrometers:

- subscribe to notify characteristics on service `0000fff0-0000-1000-8000-00805f9b34fb`
- write one-byte read commands to `0000fff8-0000-1000-8000-00805f9b34fb`
- never write to the history-delete characteristic `0000fff9-0000-1000-8000-00805f9b34fb`

If neither supported characteristic layout is present, BirdMenu saves a read-only GATT snapshot and reports that history retrieval is unsupported. It does not write unknown history commands. No history path writes to the history-delete characteristic `fff9`.

Fetched data is saved under `~/Documents/BirdMenu Logs/`. The app always writes a raw JSON dump. If the packet layout can be decoded confidently, it also writes `history.csv`.

The menu shows history progress and offers cancellation. ITH-11-B transfers allow a 15-second gap before requesting missing blocks, back off subsequent requests up to 60 seconds, and stop after 180 seconds without a new valid block. Duplicate or unrelated notifications do not extend that deadline. Continuous progress is not cut off by the old 120/300-second limits; a 40-minute overall safety limit remains. Connection/setup and command responses normally have a 30-second deadline, with 60 seconds allowed for the device's completion write.

For recognized transient connection errors, BirdMenu saves the interrupted snapshot and makes at most two automatic reconnect attempts. Each reconnect starts a **separate, fresh history request**: block numbers from different device sessions are never merged. Cross-session resume is not assumed to be supported by the sensor.

Raw checkpoints are saved during reception and on interruption. A successful empty history is shown as no new records, not a decoding error. If the complete history was saved but the final device handshake could not be confirmed, BirdMenu keeps the files and displays a warning. Quitting during a fetch waits for cancellation and the save attempt.

Use Settings to select a sensor and generate a graph for a specific local date. BirdMenu scans the saved `history.csv` files that still exist under `~/Documents/BirdMenu Logs/`, combines records only for that sensor and date, and writes a sensor-specific PNG to the logs folder. Full device IDs in raw exports are preferred; ambiguous legacy sensor IDs are reported instead of silently mixing sensors. CSV loading and graph rendering run off the UI thread.

For observed sensors, the companion-app command sequence appears to return records that have not yet been synced rather than the full retained memory every time. In practice this means repeated fetches may produce only the new records since the previous successful sync. Keep the raw JSON files if you need to audit or re-decode the captured BLE packets later.

This feature is intentionally conservative because the offline history protocol is not publicly documented and is not implemented by `inkbird-ble`.

When displaying the average of multiple sensors, freshness reflects the **oldest** included reading, so a recently received advertisement from one sensor cannot make another sensor's stale data appear current.

## Debug Logging

Enable `Debug Logging` from the menu to write received BLE data to macOS Unified Logging. The app logs decoded temperature/humidity/battery/RSSI values, raw advertisement bytes, and history-fetch GATT packets.

View recent logs with:

```sh
log show --style compact --last 10m --predicate 'subsystem == "st.rio.birdmenu"'
```

For live logs:

```sh
log stream --style compact --predicate 'subsystem == "st.rio.birdmenu"'
```

## Official App Trace Analysis

The tested sensor's offline history protocol is not exposed through `fff8` on observed units. To identify the real sync command, capture an Android Bluetooth HCI snoop log while the companion app syncs offline data, then run:

```sh
node Tools/analyze-btsnoop.js /path/to/btsnoop_hci.log
node Tools/analyze-btsnoop.js --summary /path/to/btsnoop_hci.log
node Tools/analyze-btsnoop.js --plan /path/to/btsnoop_hci.log
node Tools/analyze-btsnoop.js --json /path/to/btsnoop_hci.log > trace.json
```

The tool extracts ATT writes, notifications, and indications, including traffic around `fff0` and `5833ff01-9b8b-5191-6142-22a4536ef123`. The output is intended to identify the characteristic and command bytes used by the official app for offline history sync.

`--plan` prints non-CCCD write candidates in the order they appeared, with the response characteristic and sample notification payloads. The JSON output also includes `candidateCommandPlan`, which is the safest starting point for implementing a replay only after the trace clearly shows the official app's history-sync command.

Typical Android capture flow:

1. Enable Developer options on the Android phone.
2. Enable `Bluetooth HCI snoop log`.
3. Force stop the companion app, then reopen it.
4. Connect to the sensor and wait until the app finishes syncing offline data.
5. Export the bug report or retrieve `btsnoop_hci.log` from the phone.

The useful lines are usually non-CCCD `write_request` or `write_command` entries followed by `notification` or `indication` packets within a few seconds.

Apple PacketLogger captures from a real iPhone or iPad can also be passed to the same tool. The analyzer reports PacketLogger metadata, interesting advertisements, and whether ATT connection traffic is present. A capture that only contains LE advertising reports is not enough for offline history implementation; it must include the official app's BLE connection writes and notifications during a history sync.

## Build and Run

```sh
make run
```

The app bundle is generated at `build/BirdMenu.app`.

On first launch, macOS may ask for Bluetooth permission. Allow it so the app can receive BLE advertisements.

## BLE Parsing

The advertisement parsing follows the tested sensor behavior documented by `inkbird-ble`:

- service UUID: `0000fff0-0000-1000-8000-00805f9b34fb`
- manufacturer id: `9289`
- 18-byte advertisement payload
- temperature/humidity: bytes `[6..<10]`, little-endian signed temperature and unsigned humidity, both in tenths
- battery: byte `[10]`

The app drops impossible humidity values above 100% and battery values above 100%, matching the corruption guards used by `inkbird-ble`.

## Privacy

BirdMenu does not collect, transmit, sell, share, or track personal data. Bluetooth readings and history exports are processed locally on your Mac.

See [Privacy Policy (English)](docs/PRIVACY.en.md) and [プライバシーポリシー (日本語)](docs/PRIVACY.ja.md).

## Acknowledgements

The BLE parsing logic is based on the MIT-licensed [`inkbird-ble`](https://github.com/bluetooth-devices/inkbird-ble) project.

The history-fetch command sequence is informed by public reverse-engineering notes for related BLE hygrometers.

## License

BirdMenu is released under the MIT License. See [LICENSE](LICENSE).
