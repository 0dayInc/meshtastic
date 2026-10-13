# Firmware v2.8.1 migration and installer matrix

## Exact release boundary

This delivery targets **`v2.8.1.8e6a88d`**, firmware commit
`8e6a88d06f44cad26f1e8d7cd402939ccacb9b4c`. The expected PhoneAPI version is
**`2.8.1.8e6a88d`** (no leading `v`). The firmware's actual protobuf submodule
pin is **`8f97d66a63ce10cfb12f94203e361691647f5ad3`**, not whichever protobuf
revision happens to be current on `develop`.

Sources: [exact release and migration warnings](https://github.com/meshtastic/firmware/releases/tag/v2.8.1.8e6a88d),
[firmware protobuf gitlink](https://github.com/meshtastic/firmware/tree/8e6a88d06f44cad26f1e8d7cd402939ccacb9b4c/protobufs),
[pinned protobuf definitions](https://github.com/meshtastic/protobufs/tree/8f97d66a63ce10cfb12f94203e361691647f5ad3).

**2.8.0 was revoked** for a packet-signing defect; its signatures are not
compatible with 2.8.1. Do not substitute 2.8.0, a bare `2.8.1`, a different
build suffix, or cached metadata for this release. `verify_reboot` is a generic
exact-string verifier, not a firmware downloader/revocation service: the caller
must pin `expected_version: '2.8.1.8e6a88d'` rather than pass an untrusted value
reported by the device itself.

## Implemented installer versus board support

A board/chip label is not sufficient authorization or compatibility evidence.
Select the actual board variant, image type, installed loader and physical
endpoint. There is no automatic board selection, fallback or universal flasher.
All rows below are **hardware-unverified**. Parser acceptance does not prove that
a firmware image is safe for a specific radio, partition layout or bootloader.

| Chip / representative board | Artifact | Implemented loader / data transport | Exact-release scope and restrictions |
| --- | --- | --- | --- |
| ESP32 (e.g. T-Beam), ESP32-S3 (e.g. Heltec V3) | Matching application BIN | `:esp_rom`, USB/UART ROM | Explicit `chip`, `port`, application `offset >= 0x10000`, flash capacity; identify chip/security before erase; flash MD5 verification. No factory/merged images, stub, secure/encrypted targets or full erase. These two release artifacts were not sampled in this audit. |
| ESP32 / ESP32-S3 with compatible unified loader already installed | Matching application-update BIN | `:unified_wifi` TCP 3232 or `:unified_ble` custom GATT | Separate preparation via `request_ota`, NVS hash pin and final loader `OK`. Not PhoneAPI TCP 4403/BLE. No automatic loader installation or image/board compatibility inference. |
| ESP32-C3 / Heltec HT62 SX1262 | Application BIN | `:esp_rom`, USB/UART ROM | Exact-release application parser accepted; factory BIN deliberately rejected. Do not infer unified-loader C3 support from a release's `bleota-c3.bin`. |
| nRF52840 / RAK4631 | Intel HEX | `:swd`, trusted local OpenOCD executable and interface/target Tcl files | Exact-release parser accepted; explicit nRF52840 FICR/geometry checks before programming, `verify_image` and reset. No automatic recovery mass erase. |
| nRF52840 / RAK4631 | UF2 | `:uf2`, explicitly selected Linux mounted bootloader volume | Backend exists for application range `0x27000...0xf4000` and exact Board-ID/family; **this exact-release UF2 is rejected**, since it starts at `0x26000`. Do not trim blocks or relax bounds blindly. |
| nRF52840 / legacy Adafruit SDK11 DFU | Application-only legacy ZIP + DAT inside ZIP | `:nordic_dfu`, separate BLE DFU GATT | Backend exists, but **this release's RAK4631 OTA ZIP is rejected**: its manifest includes `dfu_version: 0.5`, while the current parser permits only the application member. This is a parser compatibility gap, not evidence the package uses Secure DFU. No conversion is attempted. |
| RP2040 / RAK11310 | UF2 | `:uf2`, explicitly selected Linux mounted bootloader volume | Exact-release parser accepted with family `0xe48bff56` and explicit 2 MiB capacity. Require selected volume's Board-ID and correct actual capacity. Copy/fsync is submission, not flash verification. |
| ESP32-C6 | Release BIN | **Unsupported** | Not in native ROM chip set; no claimed unified-loader support. |
| RP2350 (including Ethernet OTA boards) | Release UF2 / Ethernet OTA | **Unsupported** | RP2040 support does not imply RP2350 families or its OTA protocol. |
| STM32 / STM32WL | Release artifacts | **Unsupported** | nRF52840 OpenOCD support does not imply a generic STM32 installer. |
| Nordic Secure DFU, serial Nordic DFU | Secure/signed ZIP or other package | **Unsupported** | Not the implemented legacy Adafruit BLE protocol. |
| Any radio via MQTT or PhoneAPI XModem | Any image | **Unsupported image transport** | MQTT Admin preparation is distinct from upload; no synchronous MQTT reboot verifier. PhoneAPI XModem is filesystem transfer. |

Format/protocol and verifier option mismatches fail before an installer is
invoked. Backend-specific target/image validation occurs before opening a
programmer, GATT loader or destination where implemented. ROM/SWD hardware chip
checks necessarily occur after connecting but before erase. Unified OTA cannot
prove board/image compatibility: the operator must select it explicitly.

No backend offers a `full_erase:` option. The release recommends full erase and
flash **if** upgrading causes bootloops/crashes, after exporting configuration.
That recovery requires a separately authorized, board-specific tool/workflow;
this gem must not report a normal application-region write as a full erase.

## Backup and migration consent

1. Before a destructive operation, obtain explicit authorization for the board,
   endpoint, selected release/artifact, preparation/reboot, and recovery method.
   Capture the old node number and a **fresh local owner public key** over the
   trusted connection; retain the raw key only in memory/private backup. Do not
   print keys, profiles or complete Admin packets. Close competing subscribers.
2. Export and privately store a [host backup](admin-backup.md), JSON or binary
   DeviceProfile `.cfg`. A backup can contain private identity keys, channel PSKs,
   credentials, coordinates and PINs. Restrict access; do not attach it to logs.
   Excluding owner metadata does **not** exclude `security` identity keys.
3. Review a restore offline/dry-run before sending. `identity_keys: :reject` is
   the default; explicitly choose `identity_keys: :restore` only for an intended
   identity restoration. Privacy-sensitive position, telemetry and MQTT-sharing
   restores require separate `allow_privacy_changes: true`, including dry runs.
   Consent is not implicit in possessing a backup. No keys/settings are silently
   stripped to make a restore pass. A key replacement/full erase without key
   restoration will not satisfy continuity with the original identity.
4. Review the release changes: key-derived node IDs replace MAC-derived IDs;
   owner long names are limited to 24 UTF-8 bytes plus NUL; position/telemetry
   broadcasts are opt-in; precise position is restricted on known-key channels;
   first-time US region selection on the device screen now defaults to
   **LongTurbo**, not LongFast. Choose compatible region/preset deliberately.
   Do not blindly enable old sharing settings or replay a 2.7 backup wholesale.
5. After the authorized installation and any restore, reconnect and read back the
   requested state. ACKs, loader checksums and UF2 copy success are distinct from
   application boot health and persisted configuration. Keep interrupted writes
   ambiguous; never automatically replay a mutation or raw firmware bytes.

## Key-continuous post-reboot verification

`expected_node:` remains a **strict post-reboot numeric ID** check. Do not put the
old 2.7 ID there when a 2.8 key-derived ID transition is expected. Instead provide
a trusted pre-upgrade `expected_public_key:` (exactly 32 nonzero raw bytes) and
`previous_node:` (old numeric unicast ID for mapping/reporting):

```ruby
result = Meshtastic::Admin::Firmware.verify_reboot(
  transport: :serial,
  connection: { block_dev: '/dev/ttyACM0', baud: 115_200 },
  expected_version: '2.8.1.8e6a88d',
  expected_public_key: trusted_pre_upgrade_public_key, # do not log this value
  previous_node: old_node_number,
  timeout: 90
)
# Use only selected report fields; never print the backup or request options.
puts "#{result[:previous_node_id]} -> #{result[:node_id]}"
```

The same options work with explicitly selected application TCP or Bluetooth
connections, or as the `verify:` Hash on `install`. `previous_node` requires key
continuity; it is not a destination override. The verifier:

- reconnects with the selected transport and waits for configuration completion;
- fixes the connected local node as the target, then requests fresh **owner and
  metadata** with independent request-ID/source correlation;
- compares the public key and exact firmware string, rejecting another key,
  stale/wrong-source replies and a local ID change during verification;
- never scans or retries arbitrary mesh nodes to find an apparent match;
- reports `identity: :public_key_continuity`, `previous_node_num`, `node_num`,
  fixed-width `previous_node_id` / `node_id`, and `node_changed`; it returns no
  owner/key material and does not log keys or echo them in identity errors.

If both `expected_node` and `expected_public_key` are given, **both must match**.
An advanced `reconnect:` callback must return a newly connected handle of the
selected transport with configuration requested; freshness of that callback's
connection is the caller's responsibility. Cached handle metadata never suffices.
This is device-reported continuity on a trusted local connection, **not** a
cryptographic challenge, signed boot attestation or RF-delivery test. Reports do
not rewrite application destination maps: review and explicitly update them.

## Executed exact-release parser audit (no hardware)

Official archive members were retrieved from the exact release using Ruby
`open-uri`, extracted in memory with Ruby `rubyzip`, then passed to the production
Ruby parsers only. No Python, flasher, serial port, BLE radio, programmer or mount
was opened. Samples were not modified to obtain a pass.

| Official member | Bytes | Production parser result |
| --- | ---: | --- |
| `firmware-heltec-ht62-esp32c3-sx1262-2.8.1.8e6a88d.bin` | 2119088 | Accepted: ESP image/chip/checksum/SHA |
| `firmware-heltec-ht62-esp32c3-sx1262-2.8.1.8e6a88d.factory.bin` | 2184624 | Rejected: merged/trailing data |
| `firmware-rak4631-2.8.1.8e6a88d.hex` | 1966833 | Accepted: nRF52840 HEX |
| `firmware-rak4631-2.8.1.8e6a88d.uf2` | 1398784 | Rejected: 16 blocks below supported application start |
| `firmware-rak4631-2.8.1.8e6a88d-ota.zip` | 700163 | Rejected: manifest shape (`dfu_version`) |
| `firmware-rak11310-2.8.1.8e6a88d.uf2` | 1611776 | Accepted: RP2040 UF2 |

Reproduce without hardware: retrieve `firmware-esp32c3-2.8.1.8e6a88d.zip`,
`firmware-nrf52840-2.8.1.8e6a88d.zip` and `firmware-rp2040-2.8.1.8e6a88d.zip`
from the linked release; extract only the six named members to a private local
directory, then run:

```sh
bundle exec ruby -Ilib spec/support/firmware_release_artifact_audit.rb /path/to/extracted-members
```

This opt-in audit pins each member's SHA-256, asserts the documented acceptance
**or rejection**, and prints a JSON report. It is separate from the default spec
suite and does not download artifacts itself. Rejections are real compatibility
gaps, not verified installers. Hashes identify retrieved bytes, not publisher
signatures. Firmware archives/binaries are not bundled in this repository.

`firmware_migration_spec.rb` uses production ToRadio/AdminMessage/FromRadio codecs
and synchronous Admin correlation over mocked Serial/BLE/TCP hardware writes.
It covers changed mapping, exact suffix/revoked version rejection, stale cached
metadata, unrelated source/request preservation, key mismatch, strict numeric
expectation, reconnect transport mismatch and preflash option validation.
Existing firmware specs additionally exercise a real loopback PhoneAPI TCP
configuration/metadata exchange. `firmware_target_selection_spec.rb` guards
unsupported chips/protocols, full-erase claims and preflash format selection.

**Delivery step 6 remains blocked** pending the user's endpoint selection and
explicit live-operation authorization. No hardware has been contacted, staged,
prepared, erased, flashed or verified by this step.

[Installer API and transport details](admin-firmware.md)
