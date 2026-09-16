# UF2 mass-storage firmware submission

`Meshtastic::Admin::Firmware::UF2.install(opts)` validates an original UF2 image and copies it to an **explicitly selected bootloader directory**. It does not discover drives, mount filesystems, enter bootloader mode, convert `.bin` files, erase devices, or verify installed flash. Implementation and filesystem safety are currently supported on **Linux with procfs and `O_NOFOLLOW`**; other platforms fail closed rather than use an unpinned destination path.

## Prepare the device yourself

The official Meshtastic workflow is to download and extract the firmware for the **exact board**, then:

- **nRF52840:** double-click reset to enter the USB UF2 bootloader. The bootloader drive exposes `INFO_UF2.TXT`, usually alongside `CURRENT.UF2` and `INDEX.HTM`.
- **RP2040:** hold BOOTSEL while attaching USB. The drive exposes `INFO_UF2.TXT` and `INDEX.HTM`.

Read `INFO_UF2.TXT`, select its mounted directory yourself, and supply its exact `Board-ID`. Do not select a normal disk or copy identification files there. The marker is the UF2-standard identification mechanism, **not cryptographic device authentication or proof of an OS mount**. A directory deliberately populated with a matching marker can pass validation (including the temporary directories used by tests). Run as a normal user, and do not let untrusted users modify the selected directory.

## API

```ruby
require 'meshtastic/admin/firmware/uf2'

result = Meshtastic::Admin::Firmware::UF2.install(
  protocol: :uf2,
  firmware: '/absolute/path/firmware-for-your-board.uf2',
  mount: '/media/operator/BOOTLOADER',
  family_id: 0xada52840,
  board_id: 'nRF52840-YourBoard-v1' # replace with the exact observed Board-ID
)
```

Options:

| Key | Contract |
| --- | --- |
| `protocol` | Required, exactly `:uf2`; no extension-based dispatch. |
| `firmware` | Regular source file, mutually exclusive with `bytes`. Contents, not filename extension, determine validity. |
| `bytes` | Complete original UF2 binary String, mutually exclusive with `firmware`. Snapshotted before validation/copy. |
| `mount` | Required existing canonical absolute directory; no root directory, symlink components, `..`, automatic discovery or directory creation. |
| `family_id` | Required Integer: `0xada52840` (nRF52840) or `0xe48bff56` (RP2040). |
| `board_id` | Required exact case-sensitive `Board-ID` in `INFO_UF2.TXT`. nRF52840 IDs must begin with `nRF52840-` (prefix case-insensitive); RP2040 must identify as `RPI-RP2`. |
| `flash_size` | Required **only for RP2040**, actual installed flash capacity in bytes, positive 4096-byte multiple from 4096 through 16 MiB. Check the board documentation; the generic RP2040 marker cannot report physical capacity. Rejected for nRF52840. |

RP2040 example options: `family_id: 0xe48bff56, board_id: 'RPI-RP2', flash_size: 2 * 1024 * 1024` for a board actually fitted with 2 MiB flash.

Unknown options are rejected. Reboot and PhoneAPI verification belong to the parent `Firmware.install` orchestration, not this backend.

## Accepted format and address policy

This is a deliberately narrow installer, not a universal UF2 interpreter:

- Source limit: 32 MiB, nonempty and an exact multiple of 512 bytes.
- Every block must have both start magic words and the end magic word, little-endian fields, and flags **exactly `0x2000`** (family present, main flash).
- Every block family must match the explicitly selected supported MCU. Concatenated mixed-family UF2 files are rejected even though the general UF2 format permits them.
- Payloads must be 256 bytes and target addresses 256-byte aligned, the supported bootloader profile (stricter than the generic UF2 format's four-byte alignment).
- Every block count must equal the physical file block count. Block numbers must cover `0...count` exactly once. Duplicates (even identical), missing numbers, inconsistent totals and overlapping address ranges are rejected. Out-of-order blocks and address holes are allowed and copied unchanged.
- **nRF52840:** conservative application-only address window `[0x27000, 0xf4000)`, excluding MBR/SoftDevice and bootloader/UICR space. This supports the S140-v7 application layout; old S140-v6 images beginning at `0x26000`, merged SoftDevice images and custom flash layouts are deliberately unsupported. Address validation alone cannot prove application/SoftDevice compatibility. Select the board's matching release and bootloader.
- **RP2040:** XIP flash only, `[0x10000000, 0x10000000 + flash_size)`. RAM downloads are unsupported.
- Non-main-flash metadata, file containers, MD5 descriptors, extension tags, reserved flags, other MCUs (including RP2350), and separately identified bootloader-update families are rejected. Raw BIN/HEX/ZIP data is never converted or reinterpreted as UF2. This API does not implement factory erase; an erase program encoded as an otherwise ordinary application image cannot be distinguished by structural checks, so only submit trusted firmware chosen for this board.

The UF2 family identifies the MCU, **not the precise board/pinout**. INFO target checks cannot prove that a family-only image was built for that exact board; correct release selection remains the operator's responsibility. Structural validation and the returned local SHA-256 are not authenticity or device-flash verification.

## Copy and result semantics

The installer checks one case-insensitive `INFO_UF2.TXT` filename, a bounded regular nonsymlink marker, the bootloader header, an unambiguous exact Board-ID and matching MCU. It pins the selected directory with an open file descriptor and writes relative to `/proc/self/fd/<fd>` so unplugging, replacing or unmounting the selected path cannot redirect firmware into the underlying host directory.

It creates only `FIRMWARE.UF2`, using exclusive creation and no symlink following. Existing files or symlinks are never overwritten. All image and target checks occur before destination creation. It writes the original UF2 bytes without padding, address relocation or reordering, flushes, calls `fsync`, and closes the file. A successful result contains:

```ruby
{
  status: :copied, protocol: :uf2,
  bytes: 512,                  # actual source byte count, not payload count
  sha256: '...',               # digest of the submitted file
  family_id: 0xada52840,
  board_id: 'nRF52840-YourBoard-v1',
  destination: '/media/operator/BOOTLOADER/FIRMWARE.UF2',
  flash_verified: false,
  reboot_verified: false
}
```

`:copied` means host filesystem submission completed, **not that the bootloader accepted or flashed it**. UF2 mass storage has no universal flash-acknowledgment protocol. Readback of the created virtual file would not establish flash integrity, and the bootloader may disappear/reboot while the host closes or syncs the file. Any write, flush, sync or close error propagates; no disconnect is converted into success and no transfer is automatically retried. A partial file is left alone because deleting/retrying on a disappeared mount could act on the wrong filesystem or replay a partly flashed image. Inspect the device and re-enter its bootloader manually before deciding what to do next.

## Verification and limitations

RSpec uses actual temporary source files and bootloader directories, including symlinks/FIFOs, valid nRF52840/RP2040 images, invalid magic, truncation, flags, family/count/address errors, duplicate blocks, destination preservation and readback of the copied bytes. Mount replacement and disconnect-at-sync are injected around real filesystem operations. No USB device, physical flash, bootloader reboot, or on-device application health has been tested.

```sh
bundle exec rspec spec/lib/meshtastic/admin/firmware/uf2_spec.rb spec/conventions_spec.rb
```

## Sources

- [Microsoft UF2 specification](https://github.com/microsoft/uf2/blob/master/README.md): block layout, flags, alignment, family semantics and INFO identification.
- [Official UF2 family identifiers](https://github.com/microsoft/uf2/blob/master/utils/uf2families.json).
- [Meshtastic drag-and-drop nRF52/RP2040 workflow](https://meshtastic.org/docs/getting-started/flashing-firmware/nrf52/drag-n-drop/).
- [Adafruit nRF52 bootloader documentation](https://github.com/adafruit/Adafruit_nRF52_Bootloader): application start addresses, bootloader entry and separate bootloader family.
- [Adafruit UF2 bootloader implementation](https://github.com/adafruit/Adafruit_nRF52_Bootloader/blob/master/src/usb/uf2/ghostfat.c): 256-byte payload/address checks, family dispatch and INFO fields.
