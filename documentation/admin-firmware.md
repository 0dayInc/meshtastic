# Meshtastic::Admin::Firmware

Install Meshtastic firmware using the PhoneAPI / admin path (not esptool). Nested under [Admin](admin.md) because OTA is an `AdminMessage`.

## What it does

1. SHA-256 the image (`-update.bin` for ESP32 BLE/WiFi OTA).
2. Send `ota_request` (`OTAEvent`: 32-byte hash + `:OTA_BLE` or `:OTA_WIFI`) on `ADMIN_APP`.
3. On serial / TCP / Bluetooth, stream the image as `ToRadio.xmodemPacket` (SOH 128-byte blocks, CRC16, EOT). MQTT has no PhoneAPI XModem; it only publishes the admin `ota_request` so the node can reboot into OTA.

`enter_dfu` sends `enter_dfu_mode_request` (nRF52 USB UF2 / serial DFU). `reboot_ota(seconds:)` is the older `reboot_ota_seconds` field.

Use a firmware file that matches the board. Interrupting a flash can brick the radio. Keep battery high.

This is not the web flasher / `esptool` USB bootloader path, and not nRF `.zip` via `adafruit-nrfutil`.

## Methods

- `install(firmware:, mode:, serial_obj: | tcp_obj: | bluetooth_obj: | mqtt_obj:)`
- `request_ota` — admin hash + mode only
- `enter_dfu`
- `reboot_ota(seconds: 10)`
- `xmodem_blocks(bytes)` / `send_xmodem(xmodem:)`
- `sha256`
- `help` / `authors`

`mode:` is `:OTA_BLE` or `:OTA_WIFI`. `firmware:` is a path; `bytes:` is raw image bytes.

## Serial / TCP / Bluetooth

```ruby
Meshtastic::Admin::Firmware.install(
  serial_obj: serial_obj,
  firmware: 'firmware-heltec-v3-update.bin',
  mode: :OTA_BLE
)

Meshtastic::Admin::Firmware.install(
  tcp_obj: tcp_obj,
  firmware: 'firmware-heltec-v3-update.bin',
  mode: :OTA_WIFI
)

Meshtastic::Admin::Firmware.install(
  bluetooth_obj: bluetooth_obj,
  firmware: 'firmware-heltec-v3-update.bin',
  mode: :OTA_BLE
)
```

## MQTT (remote admin)

Publishes one encrypted `ADMIN_APP` envelope. The node must accept remote admin. It does not push XModem over the broker.

```ruby
Meshtastic::Admin::Firmware.install(
  mqtt_obj: mqtt_obj,
  firmware: 'firmware-heltec-v3-update.bin',
  mode: :OTA_WIFI,
  to: '!aabbccdd',
  psks: { LongFast: 'AQ==' }
)
```

## Related

- [Meshtastic::Admin](admin.md)
- [Meshtastic::Xmodem](xmodem.md)
- [Meshtastic::MQTT](mqtt.md)
