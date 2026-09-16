# Meshtastic::Admin::Firmware

**PhoneAPI XModem is not a firmware flashing protocol.** The old implementation incorrectly sent padded XModem data after an OTA admin request and could report completion without any device acknowledgement. That path is now rejected, including MQTT's former silent request-only `install`.

## Supported operations

| Operation | What the Ruby implementation actually does |
| --- | --- |
| `sha256(firmware: ... \| bytes: ...)` | Returns a raw 32-byte SHA-256 digest. Exactly one nonempty image source is required. |
| `request_ota(...)` | Sends the real ESP32 `OTAEvent` admin request: raw SHA-256 plus `:OTA_BLE` (default) or `:OTA_WIFI`. This pins the image hash and requests a reboot into an **already installed compatible loader**; it does not upload firmware or prove that the loader started. |
| `install(protocol: :unified_wifi, host: ..., firmware: ... \| bytes: ...)` | Separate ESP32 unified-loader TCP protocol, normally port 3232. Requires the image hash to have been provisioned using `request_ota`. |
| `install(protocol: :unified_ble, address: ..., firmware: ... \| bytes: ...)` | ESP32 unified-loader custom GATT protocol, with a native Ruby BlueZ backend and application ACK flow control. Not the old BLE-only firmware-ota protocol. |
| `install(protocol: :nordic_dfu, address: ..., package: ...)` | Adafruit SDK11 legacy Nordic BLE DFU for application-only legacy ZIP packages. [Exact scope and options](admin-firmware-nordic.md). Not Nordic Secure DFU or UF2. |
| `install(protocol: :esp_rom, ...)` | Native ESP ROM serial flashing with explicit chip, flash geometry and offset, ROM acknowledgements and flash MD5 verification. [Exact scope and options](admin-firmware-serial.md). |
| `verify_reboot(...)` or `install(..., verify: {...})` | Fresh application connection, matching configuration handshake and a new request-ID/source-correlated Admin device-metadata reply. Checks exact firmware version and optional node identity. |
| `enter_dfu(...)` | Sends `enter_dfu_mode_request`; current upstream handles entry on nRF52/RP2040. It neither transfers a DFU package nor copies a UF2 image. |
| `reboot_ota`, `xmodem_blocks`, `send_xmodem` | Raise `NotImplementedError`. The legacy reboot field has no handler in the inspected firmware; XModem is filesystem transfer, not firmware installation. |
| `help`, `authors` | Usage and attribution. |

Admin commands accept the transport, addressing, and authentication options documented in [Admin](admin.md). Use exactly one transport. Successful submission is **not confirmation that hardware supports or performed the operation**. A routing acknowledgement alone cannot prove an ESP32 OTA loader/partition exists. No automatic board detection is performed.

## ESP32 unified WiFi example

Only use a matching application update `.bin`, not a merged full-flash image, UF2, ZIP, or bootloader. Confirm board, flash layout, power, WiFi configuration, and loader compatibility yourself. Wrong images or interrupted writes may leave the device unbootable; keep a recovery method available.

```ruby
image = File.binread('firmware-matching-board-update.bin')

# Phase 1: use an existing authenticated Admin connection to pin this image.
Meshtastic::Admin::Firmware.request_ota(
  serial_obj: serial_obj,
  bytes: image,
  mode: :OTA_WIFI
)

# Phase 2: connect to the separate loader after it reboots and joins WiFi.
# Not the Meshtastic TCP PhoneAPI port 4403, nor an existing tcp_obj.
result = Meshtastic::Admin::Firmware.install(
  protocol: :unified_wifi,
  host: '192.0.2.10',
  bytes: image,
  port: 3232,
  timeout: 120,
  retries: 3,
  retry_delay: 1
)
# { status: :verified, bytes: ..., sha256: '64 hexadecimal characters',
#   loader_version: 'hardware firmware reboot_count loader_version' }
```

`request_ota(ota_hash: ...)` also accepts an explicitly supplied **raw** 32-byte digest (not hex). When an image is supplied alongside the digest they must match. It rejects unknown modes. The loader itself checks that the upload hash equals its provisioned NVS hash and verifies the downloaded bytes.

`install` intentionally rejects `serial_obj`, `tcp_obj`, `bluetooth_obj`, `mqtt_obj`, `mode`, mesh destinations, and other unknown options. These are not the unified WiFi transport. `host` must address the actual prepared loader. Protocol selection is explicit: no guessing or fallback to a different flasher.

### Wire behavior and failure handling

1. Connect with a bounded timeout; retry **only** connection refusal/timeouts, up to `retries` additional attempts (0..20). The default is three additional attempts with a one-second delay. Each connect has its own timeout.
2. Send `VERSION\n`; require `OK <hw> <fw> <count> <loader-version>\n` before sending an OTA command.
3. Send `OTA <exact-byte-count> <sha256-hex>\n`; accept `ERASING\n` followed by `OK\n`, or immediate `OK\n`. No image bytes are sent until this handshake succeeds.
4. Send the exact binary without XModem, padding, or EOT. Drain optional TCP `ACK\n` responses concurrently to avoid socket backpressure deadlocks. TCP handles retransmission; no firmware bytes are replayed at application level.
5. Require the final `OK\n`. `ACK`, successful socket writes, disconnects, and admin submission do not count as completion. `ERR ...`, malformed/oversized lines, premature EOF, and timeout raise errors; the connection and upload worker are cleaned up.

`timeout` also bounds the **whole VERSION/erase/upload/final-verification exchange**, not each received line. Increase it for slow devices/large images. A lost connection after starting OTA is not retried automatically: completion can be ambiguous and replaying raw bytes can corrupt the transfer. Reconnect manually and inspect the device before retrying.

`:verified` means **the loader reported successful integrity verification and boot-partition selection**. It does not mean the new application rebooted, is healthy, or matches a specific board. Independently reconnect and inspect its firmware version. This code does not authenticate the TCP server or add TLS; use a trusted local network. SHA-256 is integrity pinning, not a publisher signature.

## ESP32 unified BLE example

The compatible unified loader must already be installed and its NVS hash pinned with `request_ota(mode: :OTA_BLE, bytes: image, ...)`. Close the application transport before opening the loader; never open serial and BLE on the same radio concurrently. Identify the bootloader's **actual** address explicitly (it can differ from the application's). The backend never guesses an incremented MAC, discovers/selects another device, or pairs automatically. If BlueZ does not know the address, discover that loader explicitly before calling `install`. Application reconnection still requires normal Meshtastic BLE pairing.

```ruby
result = Meshtastic::Admin::Firmware.install(
  protocol: :unified_ble,
  address: 'AA:BB:CC:DD:EE:FF', # selected loader address
  adapter: 'hci0',
  firmware: 'firmware-matching-board-update.bin',
  timeout: 120,
  verify: {
    transport: :bluetooth,
    connection: { address: 'AA:BB:CC:DD:EE:FF', adapter: 'hci0' }, # application address
    expected_version: '2.7.1.example', # exact version from your chosen release
    expected_node: 0xaabbccdd,
    timeout: 90
  }
)
# status: :boot_verified only after a fresh matching application reply
```

Service UUID is `4fafc201-1fb5-459e-8fcc-c5c9c331914b`; writes use `62ec0272-3ec5-11eb-b378-0242ac130005`, notifications use `62ec0272-3ec5-11eb-b378-0242ac130003`. Subscribe **before** VERSION. Commands are fragmented at 20 bytes (safe for ATT MTU 23), then binary is transferred in 20-byte writes with ATT responses. Each nonfinal binary write must receive `ACK\n`; the final write must receive `OK\n`, not ACK. The source sends final OK instead of final ACK. Newline buffering handles coalesced or fragmented notification data, with a 512-byte response-line bound. Unexpected UUID, ERR, malformed/version responses, silence or missing final OK fail closed. Neither binary chunks nor uncertain sessions are automatically replayed. Conservative 20-byte chunks trade speed for MTU portability; increase the total timeout for large images. BlueZ negotiates link MTU; an undersized/truncated VERSION notification fails safely rather than bypassing the handshake.

For tests or an alternative Ruby GATT implementation, unified BLE accepts `backend:` (Nordic uses `gatt:`). The shared production class is `Meshtastic::Admin::Firmware::BLE::BlueZ.new(address:, adapter:, service_uuid:, timeout:).connect`. Its instance API is `subscribe(uuid:)`, `write(uuid:, bytes:, response: true/false)`, `notification(timeout:)` returning `{uuid:, bytes:}`, and `close`. All GATT service/characteristic lookup and notification match paths are scoped to the selected device. A private Ruby D-Bus connection is used; notification dispatch and synchronous method calls remain on the caller thread. No Python or external flasher process is used.

## Post-reboot verification

`verify:` is an **optional Hash** of `verify_reboot` options, validated before transfer. Omitting it preserves loader-only `:verified` results; it never silently claims boot health. Providing it runs verification only after the installer returns and closes its loader connection. You can also call `verify_reboot` independently.

- Required: `transport: :tcp | :bluetooth | :serial`, `expected_version:` (exact nonempty String).
- Production default: `connection:` Hash for a **new** application connection, explicitly specifying `host`, `address`, or `block_dev`, respectively. TCP uses PhoneAPI port **4403**, not updater port 3232; set `connection[:port]` only for a custom PhoneAPI port. Do not supply an existing socket/handle.
- Optional: `expected_node:` numeric node ID, `timeout:` whole-operation deadline (60 seconds), `reboot_delay:` initial wait (3 seconds).
- Optional advanced `reconnect:` callable receives `{transport:, connection:, timeout:}` and must return a newly connected handle of the selected transport, with configuration requested. The verifier still waits for configuration and issues a fresh Admin metadata request; a callback cannot substitute a cached metadata Hash. The returned handle is closed afterward.
- Pre-metadata connection/configuration I/O failures retry every 0.25 seconds within the total deadline. Metadata errors/version mismatches do not cause a reflash or get converted to success.
- A fresh source/request-ID-matched `get_device_metadata_response` is required. Cached `handle[:metadata]`, configuration metadata, loader VERSION, a routing ACK or successful port open cannot satisfy verification.
- Success merges `status: :boot_verified`, `loader_status: :verified`, `boot_verified: true`, `reboot_verified: true`, current firmware version, node number and metadata into the transfer result. Failure raises; firmware might already have been written, so inspect the device rather than blindly rerunning the installer.

This proves that the selected application responds and reports the expected version/optional identity. It does **not** cryptographically attest the running image, establish board compatibility, or test radio/RF operation. Use the correct release artifact and retain a recovery path.

## Explicit gaps

- No legacy BLE-only updater, ArduinoOTA/espota WiFi updater, Nordic Secure DFU, serial Nordic DFU, RP2040 UF2 filesystem copying, or automatic bootloader installation. Native protocol support is deliberately scoped; a board name alone does not establish its installed bootloader or transport capabilities.
- No automatic discovery, board/image compatibility parser, OTA partition creation, or firmware downloads. ESP32 unified source targets ESP32/ESP32-S3; this is not a claim that every ESP32 variant or every Meshtastic board has that loader.
- MQTT can carry an authorized preparation request; it is not an image transport or synchronous post-reboot verifier.
- Tests exercise fake GATT loaders, real Ruby D-Bus signal marshalling over UNIX sockets, loopback TCP PhoneAPI/configuration/Admin exchanges and the retained TCP uploader. No hardware was contacted or flashed; physical device compatibility and reboot behavior remain hardware-unverified.

## Upstream evidence

Inspected main firmware commit `6d41e279f1f51bd59f687b9d441c1bf47b1594fc` and unified loader commit `e7c0b95e14b6a1ffeca81b71c1ac477593911213`:

- [AdminModule.cpp](https://github.com/meshtastic/firmware/blob/6d41e279f1f51bd59f687b9d441c1bf47b1594fc/src/modules/AdminModule.cpp): `ota_request` checks the 32-byte hash, loader partition and capability; stores settings and schedules reboot. DFU entry is guarded by nRF52/RP2040 architecture. No `reboot_ota_seconds` handler appears.
- [MeshtasticOTA.cpp](https://github.com/meshtastic/firmware/blob/6d41e279f1f51bd59f687b9d441c1bf47b1594fc/src/platform/esp32/MeshtasticOTA.cpp): stores the hash in NVS and identifies combined/BLE-only/WiFi-only loader project names.
- [xmodem.cpp](https://github.com/meshtastic/firmware/blob/6d41e279f1f51bd59f687b9d441c1bf47b1594fc/src/xmodem.cpp): sequence-zero packet contains a filename; receiver uses `FSCom.open`/`file.write`. This is filesystem transfer, not an application updater.
- [Unified protocol README](https://github.com/meshtastic/esp32-unified-ota/blob/e7c0b95e14b6a1ffeca81b71c1ac477593911213/README.md): VERSION/OTA commands, GATT UUIDs, hashes and completion response.
- [ota_processor.cpp](https://github.com/meshtastic/esp32-unified-ota/blob/e7c0b95e14b6a1ffeca81b71c1ac477593911213/src/ota_processor.cpp): actual command parser, NVS hash gate, erasure, binary streaming, final hash check and boot-partition selection.
- [ble_ota.cpp](https://github.com/meshtastic/esp32-unified-ota/blob/main/src/ble_ota.cpp): custom GATT UUIDs, 4096-byte input stream buffer, ACK-enabled processor, and two-second reboot delay. [ota_processor.cpp](https://github.com/meshtastic/esp32-unified-ota/blob/main/src/ota_processor.cpp) sends ACK only for nonfinal chunks and OK after final integrity/boot-partition checks.
- [net_ota.cpp](https://github.com/meshtastic/esp32-unified-ota/blob/e7c0b95e14b6a1ffeca81b71c1ac477593911213/src/net_ota.cpp): TCP 3232 and **`setAckEnabled(true)`**. This differs from the README claim that WiFi has no application ACK. The implementation accepts either behavior. UDP discovery is emitted as broadcasts by this implementation; no discovery behavior is assumed by the Ruby client.

[Admin documentation](admin.md)
