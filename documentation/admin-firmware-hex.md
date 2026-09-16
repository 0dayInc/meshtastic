# Intel HEX over SWD — nRF52840 only

`Meshtastic::Admin::Firmware::Hex` validates Intel HEX in native Ruby and programs an explicitly selected **nRF52840** through a separately installed, trusted **OpenOCD 0.12+ executable**. No Python flashing tools are used. Other nRF52 chips, other MCU families, serial HEX upload, and automatic probe/board discovery are unsupported.

## Safety and prerequisites

Calling `install` is destructive: OpenOCD erases sectors containing image data, writes, verifies, and resets the target. Erasing a sector can remove existing bytes outside the image's populated addresses in that sector. Select the exact firmware for your board, and include any required bootloader/SoftDevice components. A syntactically valid HEX is not authenticated firmware and does not prove board compatibility. UICR records can change bootloader/protection configuration.

Supply absolute paths to an installed OpenOCD executable and **trusted local interface and nRF52 target configuration files**. Configurations are executable Tcl, not sandboxed data; never use untrusted downloaded configuration files. They must configure one intended SWD target and its flash banks without independently programming/erasing hardware. Supply its exact OpenOCD target name, normally `nrf52.cpu`, and explicit `expected_chip: :nrf52840`. The implementation selects that target and checks FICR PART (`0x52840`) and flash geometry (256 × 4096 bytes) before issuing the flash write command. This identifies the chip, not the commercial board or probe serial number. Configure probe selection in the trusted interface file when multiple probes exist.

A supported probe, correct board-specific SWD wiring/power, permissions, and working OpenOCD configuration are operator prerequisites. Protected/debug-locked targets fail: no automatic recovery, mass erase, protection bypass, or retry is performed. Runtime uses POSIX process groups for timeout cleanup.

## API

```ruby
require 'meshtastic/admin/firmware/hex'

# Validation only: no subprocess or hardware access.
metadata = Meshtastic::Admin::Firmware::Hex.validate(
  bytes: File.binread('/absolute/path/firmware-board.hex'),
  expected_chip: :nrf52840
)

# Destructive: run only when intentionally installing onto the selected hardware.
result = Meshtastic::Admin::Firmware::Hex.install(
  protocol: :swd,
  firmware: '/absolute/path/firmware-board.hex',
  expected_chip: :nrf52840,
  expected_target: 'nrf52.cpu',
  openocd: '/usr/bin/openocd',
  interface_config: '/absolute/path/trusted-interface.cfg',
  target_config: '/absolute/path/trusted-nrf52.cfg',
  timeout: 120
)
```

Use exactly one of `firmware:` (regular file) or `bytes:` (String). Input is limited to 16 MiB. `timeout` is positive finite seconds, at most 3600 (default 120). Unknown installation options are rejected. `Hex.install` does not consume a `format:` option; the parent firmware dispatcher selects `format: :hex` and forwards backend options.

Validation checks every record's ASCII hexadecimal syntax, byte count and checksum; requires exactly one terminal EOF and nonempty data; rejects blank lines, trailing records, unknown types, empty data records, 64 KiB record crossings, and overlapping physical address ranges. Types 00/01/02/04 implement data, EOF, segment and linear addressing. Types 03/05 validate a single optional start address within flash; start metadata is not used to override the reset vector. Data may occupy internal flash `[0, 0x100000)` or UICR `[0x10001000, 0x10002000)` only. LF and CRLF are accepted. `validate` returns populated byte count, sorted exclusive-end address ranges and optional start address.

The installer snapshots validated bytes in a private temporary HEX file. It launches OpenOCD with separate argv entries, never a shell command; paths embedded in Tcl are escaped including braces, quotes, backslashes and substitution characters. It disables normal GDB/Telnet/Tcl listener ports before loading configuration. Its guarded script executes:

1. `init`, target selection, `reset init`, `halt`;
2. FICR chip/geometry checks;
3. `flash write_image erase <snapshot> 0 ihex`;
4. `verify_image <snapshot> 0 ihex`;
5. `reset run`, then a unique completion marker and `shutdown`.

Any script error invokes `shutdown error`. Both successful process termination and the exact post-verification/reset marker are required. Missing/nonexecutable dependencies and failed, incomplete or timed-out subprocesses raise; uncertain flash state is never automatically retried. Temporary files are removed. Returned success is `status: :verified`, `flash_verified: true`, **`reboot_verified: false`**, with image SHA-256, image byte count, chip/target and validation metadata. Reset command completion is not evidence of a healthy Meshtastic application; perform a separate fresh PhoneAPI health/version check.

## Official workflow and limits

The [official Meshtastic nRF52 SWD guide](https://meshtastic.org/docs/getting-started/flashing-firmware/nrf52/swdio/) describes an external SWD probe, OpenOCD interface configuration, `transport select swd`, `target/nrf52.cfg`, HEX firmware, and erase/program/verify/reset commands. Its recovery example uses `nrf5 mass_erase`; this narrower installer deliberately **does not mass-erase**. Recovery requiring full erase remains an explicit separate operator workflow.

[OpenOCD flash programming](https://openocd.org/doc/html/Flash-Programming.html) documents the reset-init, flash-write, verify-image and reset-run sequence. [OpenOCD general commands](https://openocd.org/doc/html/General-Commands.html) documents failure exit via `shutdown error`.

All five `.hex` files in the official `firmware-nrf52840-2.7.26.54e0d8d.zip` [release](https://github.com/meshtastic/firmware/releases/tag/v2.7.26.54e0d8d) were validated locally, including `firmware-wio-sdk-wm1110-2.7.26.54e0d8d.merged.hex` and four RAK4631 variants. This is parser compatibility evidence, not hardware installation evidence. Tests exercise actual fake executable processes and Tcl command simulation (test dependency: `tclsh`); no development test connects to or erases hardware. No claim is made that every Meshtastic board or every historical/future HEX variant is supported.
