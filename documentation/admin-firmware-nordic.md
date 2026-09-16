# Nordic/Adafruit BLE DFU

## Supported path

`Meshtastic::Admin::Firmware::NordicDFU` installs **application-only, unsigned legacy Adafruit CRC16 DFU ZIP packages** over the SDK11 BLE bootloader protocol. It does not invoke Python, nrfutil, unzip, or any other external program. Use the correct board's `firmware-…-ota.zip`, not a UF2, HEX, raw binary, release bundle, or bootloader/SoftDevice upgrade ZIP.

This is a genuinely supported Nordic path, **not Nordic Secure DFU**. Meshtastic's application-side `BLEDfuSecure` advertises FE59 as a buttonless reboot service; that name does not establish that the bootloader implements Secure DFU's protobuf init packets and object/CRC32 transfer protocol. The Adafruit SDK11 bootloader uses legacy service 1530 and its own control-point commands.

Unsupported packages fail before any GATT writes: SoftDevice/bootloader or multi-image updates, Nordic Secure DFU init packets, Adafruit extended hash/signed init packets, encrypted/split/ZIP64 archives, data-descriptor ZIPs, missing or malformed manifest entries, inconsistent directory/local headers, duplicate or unsafe names, oversized entries, CRC32 failures, non-word-aligned binaries, and image CRC16 mismatches. Stored and raw-DEFLATE ZIP entries are supported, bounded in memory; nothing is extracted to disk.

Adafruit's optional `SIGNED_FW` build is a **different legacy init extension**, not Secure DFU: extension identifier 2, image length, SHA-256 and raw P-256 signature R/S. Its bootloader verifies a compiled-in public key. This installer rejects that extension rather than discarding signatures or silently downgrading security. Ordinary CRC16 packages provide corruption detection, **not authenticity**. Obtain the board-specific ZIP from a trusted release source. Device type 0x0052 does not uniquely identify a board; the bootloader checks the package's SoftDevice requirements but host-side board compatibility cannot be inferred from this format.

## Integration API

```ruby
require 'meshtastic'
require 'meshtastic/admin/firmware/nordic_dfu'

result = Meshtastic::Admin::Firmware::NordicDFU.install(
  protocol: :nordic_dfu,
  package: '/path/to/firmware-board-version-ota.zip',
  address: 'AA:BB:CC:DD:EE:FF',
  adapter: 'hci0',
  timeout: 30
)
```

The public signature is `install(opts = {})`. Exactly one source is required:

- `package:` — DFU ZIP filename.
- `package_bytes:` — raw ZIP String instead of a filename.

Other accepted keys: `protocol:` (optional, must be `:nordic_dfu`), `gatt:` (already-connected adapter), `address:` (required without injection), `adapter:` (default `hci0`), `timeout:` (positive finite per-notification timeout, default 30 seconds). Unknown options are rejected. In particular, no `retries:`, Secure DFU mode, or generic `bytes:`/`firmware:` aliases are silently accepted. The orchestrator should pass the ZIP source using the explicit package keys.

Production construction uses the shared BLE module:

```ruby
Meshtastic::Admin::Firmware::BLE::BlueZ.new(
  address: address, adapter: adapter, timeout: timeout,
  service_uuid: '00001530-1212-efde-1523-785feabcd123'
).connect
```

The BLE backend is shared with the unified installer; this module does not implement another BlueZ backend. BlueZ must already know the explicitly selected bootloader address. Discovery, pairing, application-to-bootloader reboot, and post-reboot reconnect belong to the caller/orchestrator.

### Exact injected GATT interface

All methods use Ruby keywords:

- `subscribe(uuid:)` enables and queues notifications before the first write.
- `write(uuid:, bytes:, response:)` writes a binary String. Control point uses `response: true`; packet characteristic uses `false`.
- `notification(timeout:)` returns `{ uuid: String, bytes: String }`, or nil on timeout; transport exceptions propagate. The implementation must enforce the supplied timeout.
- `close` releases the connection. The installer closes after an attempted session, including injected adapters. Package validation failures do not acquire or close an injected adapter.

Control UUID: `00001531-1212-efde-1523-785feabcd123`.
Packet UUID: `00001532-1212-efde-1523-785feabcd123`.
The backend resolves these only within the selected device/service and fails if absent; no fallback to unrelated characteristics or Secure DFU.

## Wire sequence and verification

1. Subscribe to control-point notifications.
2. Write Start DFU `[01 04]` (application), then three little-endian uint32 sizes `[0, 0, image_size]` to the packet characteristic. Require `[10 01 01]` success.
3. Write Init Start `[02 00]`, stream the **unchanged** `.dat` in at-most-20-byte packets, then Init Complete `[02 01]`. Require `[10 02 01]` success. Legacy init is little-endian device type uint16, revision uint16, application version uint32, SoftDevice count uint16, count uint16 IDs, then CRC16.
4. Enable packet receipt notifications with `[08 01 00]` (PRN=1); this command has no protocol response. Write Receive Firmware `[03]`.
5. Stream binary in at-most-20-byte, word-aligned packets. After each non-final packet require `[11 <received uint32 little-endian>]` with the **exact cumulative byte offset**. SDK11 sends no PRN on the final packet: instead require Receive Firmware success `[10 03 01]`, emitted after its final flash operation completes.
6. Write Validate `[04]`; require `[10 04 01]`, which confirms device-side image CRC16 validation. Only then write Activate and Reset `[05]`. This command has no DFU response; a failed ATT write is not suppressed as presumed reboot success.

The result contains `status: :verified`, `protocol: :nordic_dfu`, image `bytes:`, image `sha256:`, and `reboot_verified: false`. Verified means **bootloader validation acknowledged**, not a confirmed successful reboot or healthy Meshtastic application. The SHA-256 is computed locally for identification, not reported by the bootloader. The caller must reconnect and verify application identity/version separately.

### Retry policy

No automatic wire retries or resume. Legacy packets have no sequence number; retransmitting after an ambiguous write, missing PRN, timeout, wrong opcode, rejection, or disconnect could duplicate bytes or corrupt state. The installer closes and raises; it never sends Activate after a failed validation. The operator may explicitly restart from a newly entered bootloader session after resolving the failure. GATT/ATT link-layer retransmissions remain the Bluetooth stack's responsibility.

## Evidence and testing

The matching spec uses an independently implemented stateful DFU peer which parses every write, checks command order and sizes, accumulates `.dat`/image packets, generates PRNs from received byte counts, and calculates image CRC16 with a separate bitwise algorithm. It includes corruption/rejection/timeout/offset faults and validates ZIP parsing, supported compression, unsafe packages and production-backend construction. No hardware was opened; emulation does not prove device flash behavior or post-reboot health.

Upstream source references inspected:

- [Adafruit SDK11 BLE DFU service](https://github.com/adafruit/Adafruit_nRF52_Bootloader/blob/master/lib/sdk11/components/ble/ble_services/ble_dfu/ble_dfu.c): legacy opcodes and characteristic behavior.
- [Adafruit SDK11 BLE transport](https://github.com/adafruit/Adafruit_nRF52_Bootloader/blob/master/lib/sdk11/components/libraries/bootloader_dfu/dfu_transport_ble.c): `on_dfu_evt`, `app_data_process`, PRNs only on non-final packets, final receive response after flash completion, init/validate/reset handling.
- [Adafruit init validation](https://github.com/adafruit/Adafruit_nRF52_Bootloader/blob/master/src/dfu_init.c): device type, SoftDevice matching, CRC16 versus optional `SIGNED_FW` P-256 extension.
- [Adafruit package generation](https://github.com/adafruit/Adafruit_nRF52_nrfutil/blob/master/nordicsemi/dfu/package.py) and [init encoding](https://github.com/adafruit/Adafruit_nRF52_nrfutil/blob/master/nordicsemi/dfu/init_packet.py): manifest, `.bin`/`.dat`, default legacy v0.5 CRC16 and distinct v0.6/v0.7/v0.8 extensions.
- [Meshtastic buttonless DFU](https://github.com/meshtastic/firmware/blob/develop/src/platform/nrf52/BLEDfuSecure.cpp): FE59 application service initiates bootloader transition, not the image-transfer implementation.
- [Meshtastic NRF52 release script](https://github.com/meshtastic/firmware/blob/develop/bin/build-nrf52.sh): release OTA ZIP naming.
- [Meshtastic OTAFIX bootloader fork](https://github.com/meshtastic/Adafruit_nRF52_Bootloader_OTAFIX): device-specific bootloader deployments can differ; legacy-only support must not be generalized to every NRF52 bootloader.
