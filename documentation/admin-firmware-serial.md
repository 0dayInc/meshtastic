# Native serial ROM firmware installation

`Meshtastic::Admin::Firmware::SerialBootloader` implements Espressif's UART ROM
protocol in Ruby using the existing `uart`/`termios` dependencies. It does not
execute esptool, Python, nrfutil, or an uploaded flasher stub.

## Supported targets and boundaries

| `chip:` | Hardware identification | Write format |
| --- | --- | --- |
| `:esp32` | ROM magic register `0x40001000 == 0x00f01d83`; security eFuse reads | 16-byte FLASH_BEGIN |
| `:esp32s3` | GET_SECURITY_INFO chip ID 9 and security flags | 20-byte FLASH_BEGIN, encryption disabled |
| `:esp32c3` | GET_SECURITY_INFO chip ID 5 and security flags | 20-byte FLASH_BEGIN, encryption disabled |

Support is for **UART ROM download mode**, normally through an external USB/UART
bridge. Automatic reset requires the conventional DTR-to-BOOT and RTS-to-EN
circuit. Native USB-Serial-JTAG/USB-OTG reset and re-enumeration are not implemented.
Other chips, including ESP8266, ESP32-S2, C2, C6, H2 and Nordic nRF52, are rejected.
No device was physically flashed during development: verification uses an
independent ROM emulator over a PTY and the real UART opener.

Only a **single, unmerged ESP application `.bin`** is accepted. This is not a
factory/recovery installer: it does not install a bootloader, partition table,
filesystem, OTA selection metadata, UF2 image, ZIP package, signed image or merged
release image. The existing bootloader and partition table must already be valid.
Trailing padding, signatures and merged images are deliberately rejected.

## Direct API

```ruby
require 'meshtastic'
require 'meshtastic/admin/firmware/serial_bootloader'

result = Meshtastic::Admin::Firmware::SerialBootloader.install(
  protocol: :esp_rom,
  port: '/dev/ttyUSB0',
  chip: :esp32s3,
  firmware: '/path/to/board-matched-application.bin',
  offset: 0x10000,           # example only: consult this board's partition table
  flash_size: 4 * 1024 * 1024, # actual physical capacity, not image length
  reset: :classic,
  timeout: 120
)
```

Supply exactly one of `firmware:` (path) or `bytes:` (binary String). `protocol:`
is optional on the direct backend and defaults to `:esp_rom`. Unknown options
raise `ArgumentError` before opening the serial device.

- `port:` is a required dedicated serial device path, **not** `serial_obj:` from
  an active Meshtastic PhoneAPI connection. Close that connection and stop its
  reader before installing. Never flash while another process uses this port.
- `chip:` is required and must match both the image header and the connected ROM.
- `offset:` is required, at least `0x10000`, and aligned to a 4096-byte flash sector.
  This check prevents writes into low-address bootloader/partition metadata; it
  does **not** discover which application partition the board actually boots.
- `flash_size:` is required, a power of two between 1 and 16 MiB. It is declared
  by the caller; this backend does not probe JEDEC flash capacity. The complete
  sector-rounded erase range must fit within it.
- `reset: :classic` (default) drives DTR/RTS to enter ROM, then pulses EN after
  verified completion. If the bridge does not support modem-control ioctls, the
  operation fails rather than assuming a reset occurred.
- `reset: :none` means the operator has already entered ROM download mode. It
  suppresses modem-line changes, not the final FLASH_END reboot request. Opening
  a UART can still affect modem lines on some operating systems/bridges.
- `timeout:` is a finite positive per-command deadline, default 120 seconds.
  SYNC has at most three attempts, each capped at one second. The whole transfer
  can take longer than `timeout:`. Data, erase and reboot commands are not replayed
  after a timeout or rejection.

**Before flashing:** verify the board model, hardware revision requirements,
partition address and partition capacity independently. The ESP image chip ID is
not a board model identifier. This backend does not validate minimum silicon
revision against eFuses, discover partitions, select an inactive OTA slot, or
change OTA selection metadata. It cannot guarantee that the next boot selects
this image. Back up configuration before installing. Sector erase destroys the
rest of the final sector, even where the image itself ends earlier. Do not use an
offset/range belonging to NVS, a filesystem, another application or OTA metadata.

## Protocol and verification

Before opening the port, validation checks image magic, segment count and bounds,
segment word alignment, embedded chip ID, segment XOR checksum, the appended
SHA-256 digest when present, and exact end-of-image. These are corruption checks,
not firmware authenticity or signature verification.

The backend then:

1. Opens UART at 115200, 8N1, disables inherited RTS/CTS flow control and HUPCL,
   and performs the requested reset.
2. Sends escaped SLIP SYNC and accepts a nonzero ROM response value. A zero value
   is rejected as a running flasher stub. Extra ROM SYNC responses are drained
   while waiting for the next matching command response.
3. Identifies the chip and rejects secure boot, secure download, or any programmed
   flash-encryption count. Conservatively rejecting even previously used encryption
   counters avoids silently treating a security-configured device as plain flash.
4. Sends SPI_ATTACH with default pins and SPI_SET_PARAMS for declared NOR capacity.
   Custom SPI pin mappings and NAND are unsupported.
5. Erases the selected range via FLASH_BEGIN, then sends 1024-byte FLASH_DATA
   blocks with sequence numbers, `0xff` final-block padding and XOR checksum
   seeded with `0xef`. Every command requires a matching response and successful
   ROM status. Invalid framing, opcode, length, timeout or error status aborts.
6. Requests SPI_FLASH_MD5 over the **original unpadded image length** and compares
   the ROM's 32 ASCII hexadecimal characters with Ruby's MD5 of the exact source.
   A mismatch prevents FLASH_END and explicit hard reset.
7. Sends FLASH_END with reboot requested, requires its acknowledgment, and performs
   the final EN pulse for `:classic`. The UART closes on success or failure.

On success the return hash contains:

```ruby
{
  status: :verified,
  chip: :esp32s3,
  bytes: image_byte_count,
  offset: application_offset,
  md5: rom_verified_hex_md5,
  sha256: source_hex_sha256,
  reboot_requested: true,
  boot_verified: false
}
```

`:verified` means **the ROM-reported flash digest matched**. It is not a
post-reboot health check or a guarantee the booted application is this image.
Automatic Admin session/readback and post-reboot verification belong in the
higher-level Firmware orchestrator, after this backend has closed its UART.
The backend does not return an invented firmware version or treat port reopening
as proof of application health. On failure it raises `ArgumentError`, `IOError`,
`EOFError`, `Timeout::Error`, or the underlying filesystem/serial exception. A
failed transfer may have already erased or partially written the application;
no rollback is implemented.

## Unsupported commands and Nordic DFU

Implemented ROM commands are SYNC (`0x08`), READ_REG (`0x0a`, ESP32 only),
GET_SECURITY_INFO (`0x14`, S3/C3), SPI_ATTACH (`0x0d`), SPI_SET_PARAMS (`0x0b`),
FLASH_BEGIN/DATA/END (`0x02`/`0x03`/`0x04`) and SPI_FLASH_MD5 (`0x13`).

There is no compressed flashing, RAM/stub upload, arbitrary register writing,
baud-rate change, encrypted write, secure-download controller, raw flash readback,
full-chip erase, or stub-only `0xd0`/`0xd1`/`0xd2` erase/read protocol. ROM MD5 is
not interchangeable with the stub's 16-byte binary digest response.

Adafruit's nRF52 serial/CDC DFU is a **different protocol**: its upstream uploader
uses reliable HCI/SLIP framing with sequence acknowledgments, CRC16 and Nordic
START/INIT/DATA/STOP records. It is not ESP SLIP command framing, PhoneAPI framing,
a UF2 copy, or Nordic Secure DFU's object protocol. This backend explicitly does
not implement it or invoke its Python uploader. A correct future backend needs
package/init-packet validation, exact bootloader capability matching, acknowledged
HCI sequencing and honest device validation/activation evidence; transport ACKs
alone must not be reported as a verified installation.

## Sources and tests

Protocol choices were checked against the official source, not inferred from a
successful port open:

- [Espressif serial protocol reference](https://docs.espressif.com/projects/esptool/en/latest/esp32/advanced-topics/serial-protocol.html)
- [Espressif command implementation](https://github.com/espressif/esptool/blob/master/esptool/loader.py)
- [ESP32 target/eFuses](https://github.com/espressif/esptool/blob/master/esptool/targets/esp32.py),
  [ESP32-S3](https://github.com/espressif/esptool/blob/master/esptool/targets/esp32s3.py),
  [ESP32-C3](https://github.com/espressif/esptool/blob/master/esptool/targets/esp32c3.py)
- [Espressif image format parser](https://github.com/espressif/esptool/blob/master/esptool/bin_image.py)
- [Classic reset sequence](https://github.com/espressif/esptool/blob/v4.8.1/esptool/reset.py)
- [Adafruit nRF52 bootloader](https://github.com/adafruit/Adafruit_nRF52_Bootloader)
- [Adafruit serial DFU transport](https://github.com/adafruit/Adafruit_nRF52_nrfutil/blob/master/nordicsemi/dfu/dfu_transport_serial.py)

Run the hardware-free tests:

```sh
bundle exec rspec spec/lib/meshtastic/admin/firmware/serial_bootloader_spec.rb
```

The emulator independently checks wire framing, little-endian command fields,
sequence numbers, block padding/checksums, chip-specific FLASH_BEGIN layout and
verification range. Tests cover all three chips, file input, optional image
digests, classic reset controls, security/chip mismatches, malformed/error replies,
MD5 mismatch, timeouts, synchronization retry, resource teardown and rejection
before opening a device. Actual board behavior remains hardware-unverified.
