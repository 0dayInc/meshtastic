# Meshtastic::MeshInterface

Packet builder used by Serial, Bluetooth, TCP, and MQTT. Instantiated internally; you can also call it directly to get protobuf bytes without writing a radio.

## Instance methods

- `initialize(debug_out:, is_connected:, is_proto:, no_nodes:)`
- `generate_packet_id(last_packet_id:)`
- `get_cipher_keys(psks:)` — normalize Base64 PSK hash keys
- `gps_search(lat:, lon:)` — Geocoder reverse lookup
- `start_config` — `ToRadio.want_config_id` bytes
- `my_node_info`
- `send_packet` — encrypt when `psks` present; `via: :radio` → `ToRadio`, `via: :mqtt` → `ServiceEnvelope`
- `send_data` / `send_text`
- `send_to_radio` / `send_to_mqtt` — serialize only
- `decode_payload` — shared protobuf/text/binary decoding; [complete port inventory](#receive-payload-coverage)
- `decrypt_packet` — selected channel AES-CTR only; ciphertext preserved on failure
- `help` / `authors`

On Serial/Bluetooth/TCP, transports pass `psks: nil` so the radio owns channel crypto. MQTT must pass `psks`.

`send_data` and `send_packet` preserve `pki_encrypted: true` and `public_key:`
(32 raw bytes) for remote administrative requests. The connected radio performs
the public-key encryption; the Ruby client does not encrypt these packets itself.
Explicit PKI requests reject MQTT and host-side PSK encryption instead of silently
falling back to channel encryption. Supplying a recipient key does not grant admin
rights: the target must authorize the sending radio's key.

`send_text` refuses payloads larger than `Meshtastic::Constants::DATA_PAYLOAD_LEN`.

## Example

```ruby
mesh = Meshtastic::MeshInterface.new
bytes = mesh.start_config

text_bytes = mesh.send_text(
  from: '!11223344',
  to: '!ffffffff',
  channel: 0,
  text: 'Hello',
  via: :radio,
  psks: nil
)

envelope = mesh.send_text(
  from: '!c0ffee00',
  to: '!ffffffff',
  channel: 93,
  text: 'Hello MQTT',
  via: :mqtt,
  psks: { LongFast: 'AQ==' }
)
```

## Receive payload coverage

All four subscriptions use the same `MeshInterface#decode_payload` registry:

- Serial reads `0x94 0xC3` length-prefixed `FromRadio`, then `Serial.enrich_packet`.
- TCP delegates its framed stream and subscription to Serial.
- Bluetooth reads raw `FromRadio` from GATT, then calls `Serial.enrich_packet` (no UART framing).
- MQTT reads `ServiceEnvelope`, decrypts only if needed, then calls `decode_payload`.

`recv_from_radio`, `drain_from_radio`, and raw buffer APIs intentionally return the
original protobufs rather than enriched subscription hashes. Non-packet `FromRadio`
variants remain decoded by their generated outer schema.

Known protobuf payloads return a Hash, including `{}` for valid empty/default
messages. This applies when `Data#to_h` omits the payload entirely; nil is **not** a
reason to skip a known schema. Both numeric and symbolic portnums work. Unknown or
opaque bytes remain a binary String (an omitted unknown payload stays nil). Text
is UTF-8 with invalid sequences scrubbed for display: that returned text is not
lossless, but decoding does not mutate the input bytes. A malformed known protobuf returns its
original bytes rather than killing the subscription; a String at a protobuf port
therefore means parsing failed. Existing position/MAC/public-key/time enrichment
remains. Use `include_raw: true` when exact original wire bytes are needed, including
unknown protobuf fields, which `to_h` does not expose.

The inventory below covers **all 41 bundled enum entries**, verified against
[protobufs at 51028ca5](https://github.com/meshtastic/protobufs/blob/51028ca5a6945c76d3977c2bb803f9947d319ac5/meshtastic/portnums.proto)
and [firmware at 8ef996f5](https://github.com/meshtastic/firmware/blob/8ef996f5b474300c9f06128beff5ce36369f812e/src/mesh/generated/meshtastic/portnums.pb.h).
Schema selection was also checked against firmware module handlers (including
KeyVerification, StatusMessage, PowerStress and the simulator `Compressed` wrapper).
Several existing bundled application schemas were missing from the receive decoder.
The separate Forwarder decoder adds the pinned libcotshrink protobuf graph rather
than guessing that protocol from Meshtastic's similarly named TAK messages.

| ID | Port | Subscription payload / limitation |
|---:|---|---|
| 0 | UNKNOWN_APP | Raw, undefined binary; **not** `Data` |
| 1 | TEXT_MESSAGE_APP | UTF-8 text |
| 2 | REMOTE_HARDWARE_APP | `HardwareMessage` |
| 3 | POSITION_APP | `Position` |
| 4 | NODEINFO_APP | `User` |
| 5 | ROUTING_APP | `Routing` (empty/default ACK supported) |
| 6 | ADMIN_APP | `AdminMessage` |
| 7 | TEXT_MESSAGE_COMPRESSED_APP | Unishox2 default-preset text; malformed bytes preserved |
| 8 | WAYPOINT_APP | `Waypoint` |
| 9 | AUDIO_APP | Codec2 mode/header/frame Hash; PCM is opt-in via `PayloadFormats` |
| 10 | DETECTION_SENSOR_APP | UTF-8 text; **not** `DeviceState` |
| 11 | ALERT_APP | UTF-8 text |
| 12 | KEY_VERIFICATION_APP | `KeyVerification` |
| 13 | REMOTE_SHELL_APP | `RemoteShell`; stream body remains bytes |
| 32 | REPLY_APP | Text (ASCII wire convention) |
| 33 | IP_TUNNEL_APP | IPv4/IPv6 base headers and raw body; no network injection |
| 34 | PAXCOUNTER_APP | `Paxcount` |
| 35 | STORE_FORWARD_PLUSPLUS_APP | `StoreForwardPlusPlus`; encrypted/fragmented body remains bytes |
| 36 | NODE_STATUS_APP | `StatusMessage` |
| 37 | MESH_BEACON_APP | `MeshBeacon` |
| 38 | PAGING_APP | Raw: upstream enum names `PagingPacket`, but neither audited source tree defines that schema |
| 64 | SERIAL_APP | Raw serial bytes; **not** `SerialConnectionStatus` |
| 65 | STORE_FORWARD_APP | `StoreAndForward` |
| 66 | RANGE_TEST_APP | Text (ASCII wire convention); **not** `FromRadio` |
| 67 | TELEMETRY_APP | `Telemetry` and its nested metrics |
| 68 | ZPS_APP | Unsupported status + raw bytes by default; explicit legacy profile via `PayloadFormats` |
| 69 | SIMULATOR_APP | `Compressed` wrapper; `data` recursively decoded by its `portnum`, up to eight wrappers |
| 70 | TRACEROUTE_APP | `RouteDiscovery` |
| 71 | NEIGHBORINFO_APP | `NeighborInfo` |
| 72 | ATAK_PLUGIN | `TAKPacket`; Unishox2 Contact/GeoChat fields decompressed before UTF-8 parsing; detail remains bytes |
| 73 | MAP_REPORT_APP | `MapReport` |
| 74 | POWERSTRESS_APP | `PowerStressMessage` |
| 75 | LORAWAN_BRIDGE | `LoRaWANBridge`; embedded radio frames remain bytes |
| 76 | RETICULUM_TUNNEL_APP | Reticulum tunnel fragment/REQ metadata and raw bytes; opaque body, explicit reassembly only |
| 77 | CAYENNE_APP | Cayenne LPP typed records; unknown type stops parsing and retains remainder |
| 78 | ATAK_PLUGIN_V2 | Flags-prefixed `TAKPacketV2`; raw `0xFF` or official zstd dictionaries 0/1 (requires libzstd) |
| 79 | LORA_OTA_APP | ota-common header, START/LOAD bodies; no signature verification or firmware installation |
| 112 | GROUPALARM_APP | Raw external protocol; no bundled schema |
| 256 | PRIVATE_APP | Raw application-owned bytes |
| 257 | ATAK_FORWARDER | Chunk header, discovery, protobuf/GZIP libcotshrink; EXI unsupported; no automatic grouping |
| 511 | MAX | Enum limit, not an application schema; raw |

Other numeric/private ports preserve bytes without attempting arbitrary protobuf
detection. Unsupported private/unknown payloads are returned without warnings
or payload dumps. Decoding does not implement application state machines, automatic
fragment grouping, shell execution, paging acknowledgement, or inner decryption.

### Binary codecs and limits

`PayloadFormats` ports return Hashes with `:raw`, `:status` (`:decoded`,
`:unsupported`, or `:malformed`) and available format fields. A malformed packet
never discards its original bytes. Subscriptions use `pcm: false` and no ZPS
profile: call `Meshtastic::PayloadFormats.decode(portnum:, payload:, pcm: true)`
for optional libcodec2 PCM, or pass `zps_profile: :esp32_legacy` only for that
experimental sender dialect. Neither native audio playback nor packet-stream
synthesis is automatic. See [PayloadFormats](payload-formats.md).

Unishox2 and ATAK decoding are bounded to 4096 decoded bytes. ATAK V2 uses
flags-prefixed wire frames, not naked protobuf bytes; `0xFF` denotes uncompressed
protobuf. For compatibility, absent/empty V2 application payloads still yield
`{}`; direct `ATAK.decode_v2` requires a flags byte. Invalid compressed bytes or
unavailable libzstd return original wire bytes in subscriptions. The `fiddle` gem
is a packaged runtime dependency, not assumed bundled with Ruby.

[Forwarder](forwarder.md) consumes the port-257 chunk header, including `0x01`
for single-packet events. Multi-chunk packets yield fragment metadata; callers
must explicitly group a complete message before `Forwarder.decode_chunks`.
There is no application message ID and no safe automatic concurrent grouping.
GZIP protobuf events return schema-level detail, not reconstructed CoT XML;
EXI stays raw because its grammar decoder is unsupported. Packed timestamps
retain sender-relative offsets unless explicit year/timezone context is supplied
to the direct Forwarder API. Legacy `ATAK.compress_cot`/`decompress_cot` zlib
helpers are not the upstream Forwarder framing protocol.

### Simulator wrapper decoding

[Reticulum](reticulum.md) decodes the pinned port-76 tunnel header and `REQ`
control frames on all four receive paths, including inside simulator wrappers.
Malformed frames retain their original bytes. Fragment bodies remain opaque;
call `Reticulum.decode_chunks` only with an explicitly isolated complete group.
There is no automatic grouping, retransmission, inner RNS decoding or decryption.

`SIMULATOR_APP` retains the `Compressed` wrapper Hash and decodes its `:data`
through the same application dispatcher using the contained `:portnum`. Omitted
portnums mean zero (`UNKNOWN_APP`), so their data stays raw. Omitted data for a
known protobuf port decodes as the default message; an entirely empty wrapper
remains `{}`. Existing enrichment and `gps_metadata` also apply to inner messages.

At most eight simulator wrappers are decoded per call. A further simulator
wrapper remains its original binary bytes; a non-simulator leaf at that boundary
still decodes normally. Malformed outer wrappers remain raw, and malformed inner
messages remain raw in `:data`, without discarding successfully decoded wrappers.
This is schema dispatch, not decompression of arbitrary bytes.

### Encryption boundary

`decrypt_packet(message:, psks:, channel:)` preserves already-decoded packets,
even if PKI metadata is present. MQTT selects the exact `ServiceEnvelope.channel_id`
(string or symbol PSK key), using the topic channel only when the envelope omits it.
It never falls back from an unknown channel to LongFast. Radio ciphertext carries
an eight-bit XOR hash of channel name and key, not a local channel slot; only a
unique matching configured name/key is selected. Hash collisions are refused.
Supply the actual firmware channel name and full Base64 16- or 32-byte key.
Subscription wrappers also accept the existing `LongFast: 'AQ=='` shorthand.

PKI ciphertext is never fed to an AES channel cipher. Missing/ambiguous/invalid keys
and malformed decrypted `Data` preserve ciphertext with `:decryption_error`.
Successful channel decoding retains the existing `encrypted: :decrypted` marker.
AES-CTR is unauthenticated: valid protobuf parsing is not proof the key was correct
or the sender authentic. Device-owned private-key decryption remains the radio's
responsibility. No private-key discovery or downgrade fallback is performed.

### Verification

Shared independent fixtures exercise every enum through real PTY UART framing,
TCP stream framing, fake GATT reads, and both already-decoded and AES-encrypted
MQTT envelopes. Every mapped protobuf is tested with populated, empty/default,
and malformed payloads followed by further packets. These are hardware-free host
protocol tests, not claims of live radio/broker interoperability.

## Related

- [Meshtastic::Serial](serial.md)
- [Meshtastic::MQTT](mqtt.md)
- [Meshtastic::Portnums](portnums.md)
