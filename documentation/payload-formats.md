# Binary application payload formats

`Meshtastic::PayloadFormats` is a Ruby, transport-independent decoder. It does not
open radios, send packets, install firmware, or alter the original payload.

```ruby
require 'meshtastic/payload_formats'

result = Meshtastic::PayloadFormats.decode(
  portnum: :CAYENNE_APP, # alternatively integer 77
  payload: ['03670110056700ff'].pack('H*')
)
# result[:records] contains channel 3 / 27.2 C and channel 5 / 25.5 C.
```

## Integration contract

Call `decode(portnum:, payload:, pcm: false, zps_profile: nil)` using a Ruby options
Hash. `payload` must be a String of actual binary bytes, **not base64 or hex**.
Numeric ports, enum symbols, and enum-name strings are supported. `PORTS` maps
these enum names to numbers. No protobuf or shared dispatcher changes are required
inside this module; callers must explicitly require and invoke it.

Every result retains `:raw` (binary String) and `:portnum`. `:status` is:

- `:decoded`: the documented format layer was decoded, not necessarily its nested
  application content, cryptographic identity, or audio samples.
- `:unsupported`: an unknown schema/version/type remains opaque; `:error` explains
  why. Known partial fields may be present.
- `:malformed`: a known format failed bounds/framing validation; original bytes
  and an error remain available. No partial success is claimed.

Invalid Ruby input types raise `ArgumentError`. Malformed on-wire input returns a
Hash instead of disrupting a receive callback. A dispatcher should preserve these
statuses and raw bytes rather than displaying unsupported bytes as text. This
module does not decrypt encrypted MeshPackets.

| Port | Name | Decoded layer |
|---|---|---|
| 77 | `CAYENNE_APP` | Original myDevices Cayenne LPP sensor records |
| 33 | `IP_TUNNEL_APP` | IPv4 header/options or IPv6 base header, remaining bytes |
| 9 | `AUDIO_APP` | Firmware Codec2 magic/mode/framing; optional native PCM |
| 79 | `LORA_OTA_APP` | Pinned ota-common transport header and verified body layouts |
| 68 | `ZPS_APP` | Opaque by default; explicit experimental ESP32 dialect available |

Other ports remain opaque. Do not apply the ZPS dialect to arbitrary private-port
traffic simply because the historical implementation used `PRIVATE_APP`.

## Cayenne LPP

Records preserve wire order and repeated channels. Each contains `channel`,
`type`, `name`, `value`, and `unit`. Supported original type IDs are 0, 1, 2, 3,
101, 102, 103, 104, 113, 115, 134, 136. Signed big-endian values use the source
resolutions, including 24-bit signed GPS latitude/longitude/altitude. Acceleration
and gyrometer values use `{x:, y:, z:}`; GPS uses
`{latitude:, longitude:, altitude:}` in degrees/degrees/metres.

An unknown type stops decoding at its channel byte: because LPP has no generic
length field, skipping it would invent a layout. Earlier valid records,
`undecoded_offset`, and `remainder` are returned. Fork-specific extended LPP types
are not inferred. An empty LPP payload is an empty record list.

## IP tunnel

The official tunnel sends raw IP datagrams, without an Ethernet or TUN prefix.
IPv4 decoding validates IHL and exact total length, extracts addresses, protocol,
TTL, DSCP/ECN byte, identification, flags, fragment offset **in bytes**, checksum,
raw options and `body`. `header_checksum_valid` reports the checksum separately:
a bad checksum does not erase an otherwise readable header.

IPv6 decoding validates its fixed header and exact payload length, extracts
addresses, traffic class, flow label, next-header and hop-limit, and preserves
`body`. IPv6 jumbograms remain unsupported. The Python tunnel implementation is
IPv4-oriented; parsing an IPv6 header here does not claim IPv6 forwarding support
in that client. Neither parser reassembles fragments, decodes upper-layer
TCP/UDP/ICMP, walks IPv6 extension headers, or validates transport checksums.

## Audio and optional native Codec2

The firmware payload begins `C0 DE C2`, followed by a **Codec2 mode ID**, not a
literal bitrate. IDs 0–7 correspond to 3200, 2400, 1600, 1400, 1300, 1200, 700,
700B. Mode 8 is the documented modern Codec2 700C extension. Each compressed
frame occupies `ceil(bits_per_frame / 8)` bytes: 8, 6, 8, 7, 7, 6, 4, 4, 4.
A final partial frame is malformed. Padding bits in 52-/28-bit modes are not
reinterpreted as another frame.

By default, `frames` and `encoded` contain compressed bytes. `pcm_decoded: false`
means **no waveform has been produced**, even though framing is decoded.

```ruby
result = Meshtastic::PayloadFormats.decode(
  portnum: 9,
  payload: audio_payload,
  pcm: true
)
# On success: result[:pcm] is mono signed 16-bit little-endian, 8000 Hz.
# Check result[:pcm_decoded], not merely result[:status].
```

Optional PCM conversion uses Ruby Fiddle calling an installed `libcodec2.so`;
there are no shell commands, Python dependencies, playback or file writes.
Frame geometry is checked against the native library before entering its decoder.
Unavailable Fiddle/library/mode produces `pcm_error` without losing framing or
raw bytes. Modern libcodec2 often lacks the historical 700/700B modes. The binding
creates a fresh decoder per packet and retains state **within** its frames, not
across successive mesh packets. Therefore this is packet-local waveform decoding,
not a continuous-stream audio player or a guarantee of bit-identical firmware
post-filter output. Library loading currently uses the Linux shared-object name;
other platforms can still use pure-Ruby framing.

## OTA: decoding is not signature verification

This implementation targets `caveman99/ota-common` at
`e0d0e37d23a21df093981b40a09b454b9ce1c327`, not a fictional protobuf or a different
ESP32 Wi-Fi/BLE loader protocol. Frames contain an 8-byte header:
`type:u8, session:u8, index:u16le, offset:u16le, total:u16le`; maximum frame size is
233 bytes. `index == 65535` denotes the manifest unit where that frame type uses
an index.

- START (1): 12-byte geometry body, exposed as `start` with `block_size`,
  `block_count`, `payload_length`, `manifest_length`, `signature_length`.
- MANIFEST (2), BLOCK (3), PROOF (4): `body` is a fragment of the unit. Bounds are
  checked against `offset`/`total`. Empty single-leaf proofs are valid.
- REQUEST (5), ACK (6), DONE (7), ABORT (8), LOAD_COMMIT (10): header-only control
  frames according to the verified sender conventions.
- LOAD (9): 8-byte little-endian `total_length:u32, offset:u32` prefix followed by
  `chunk`, exposed as `load`; package bounds are checked.
- ANNOUNCE (11): its enum/header is known, but its body layout is not defined in
  the pinned transport codec. Its body remains opaque with `:unsupported`.
  Unknown future frame types receive the same treatment.

`signature_verified` is always false. These are **source-verified layouts**, not
cryptographically verified messages. No cross-frame reassembly, manifest parsing,
Merkle-proof checking, XEdDSA signature verification, flash state or OTA session
completion is claimed. START geometry is an unsigned hint; even an ACK/DONE
packet is not independent evidence that an image was installed.

## ZPS: explicit experimental profile only

The registry says “arrays of int64 fields,” which is not enough to establish a
portable schema. The linked original project has a concrete ESP32 implementation
but still sends on `PRIVATE_APP`; it uses native-memory `uint64_t` copies, has no
version marker, and documents unfinished behavior. Accordingly port 68 remains
opaque unless the caller knows the sender and explicitly supplies
`zps_profile: :esp32_legacy`.

That profile follows commit `8d56d8e29f24e6f5eeeae20e9daa04d1d5cd3fc3`:
little-endian timestamp/header word, position/reserved word, followed by up to
20 packed scan words. It returns the timestamp, raw header words, Wi-Fi/BLE
records (address, channel marker and negative RSSI), and optional raw signed
latitude/longitude integers plus PDOP when bit 47 indicates a position. No
geolocation service, units normalization for PDOP, or universal port-68
compatibility is implied.

## Primary sources and fixture provenance

- [myDevices CayenneLPP README](https://github.com/myDevicesIoT/CayenneLPP/blob/master/README.md):
  original type table and literal temperature/acceleration wire examples used in
  specs. Additional edge vectors follow that table.
- [Meshtastic port registry](https://github.com/meshtastic/protobufs/blob/master/meshtastic/portnums.proto):
  port assignments and encoding descriptions; the registry alone is not treated
  as a complete schema.
- [Official tunnel implementation](https://github.com/meshtastic/python/blob/master/meshtastic/tunnel.py),
  [RFC 791](https://www.rfc-editor.org/rfc/rfc791),
  [RFC 8200](https://www.rfc-editor.org/rfc/rfc8200): raw IP payload and headers.
  IPv4 fixture instantiates RFC 791 figure 5 with test addresses/data and a
  computed valid checksum; IPv6 fixture is a constructed RFC-format datagram.
- [Firmware AudioModule](https://github.com/meshtastic/firmware/blob/6d41e279f1f51bd59f687b9d441c1bf47b1594fc/src/modules/esp32/AudioModule.cpp),
  [historical Codec2 header/source](https://github.com/deulis/ESP32_Codec2/tree/a2bb5afb0c3f28f49bb77bcde65abbf9416be99d/codec2),
  [modern Codec2 API](https://github.com/drowe67/codec2/blob/main/src/codec2.h):
  magic, mode IDs, frame sizes and native calls. Specs exercise native
  encoder-produced bytes, not a mocked PCM decoder. Pattern-byte framing vectors
  test boundaries, not speech fidelity.
- [ota-common transport header](https://github.com/caveman99/ota-common/blob/e0d0e37d23a21df093981b40a09b454b9ce1c327/include/ota_common/transport.h),
  [codec/senders](https://github.com/caveman99/ota-common/blob/e0d0e37d23a21df093981b40a09b454b9ce1c327/src/transport.cpp),
  [upstream tests](https://github.com/caveman99/ota-common/blob/e0d0e37d23a21df093981b40a09b454b9ce1c327/test/test_transport/test_transport.cpp):
  header vector uses upstream `{Block,7,1234,200,1024}`; START geometry uses its
  `{1024,50,50000,192,64}` example, serialized to literal little-endian bytes.
- [ZPS original source](https://github.com/a-f-G-U-C/Meshtastic-ZPS/tree/8d56d8e29f24e6f5eeeae20e9daa04d1d5cd3fc3):
  `outBufAdd`, `encodeBSS`, `encodeBLE`, `allocReply`, and `handleReceived` define
  the explicitly selected dialect. Tests instantiate those layouts with dummy
  addresses; they are not captured port-68 packets.

Tests do not require hardware or network access. They distinguish published
vectors, independently produced native Codec2 output, and constructed
source-conformant boundary fixtures. No claim of live transport/firmware testing
is made by this module's isolated specs.
