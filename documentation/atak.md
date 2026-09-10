# Meshtastic::ATAK

TAK / ATAK over Meshtastic. Three wire formats, same as the official clients:

| Format | Port | Payload |
| --- | --- | --- |
| V1 `ATAK_PLUGIN` | 72 | Bare `TAKPacket` (PLI, GeoChat, optional `detail` bytes) |
| V2 `ATAK_PLUGIN_V2` | 78 | `[flags][TAKPacketV2]`. This gem emits uncompressed frames (`flags=0xFF`) |
| V1 `ATAK_FORWARDER` | 257 | zlib-compressed CoT XML (single packet, max `DATA_PAYLOAD_LEN`) |

V2 typed payloads: GeoChat, aircraft, shapes, markers, range-and-bearing, routes, CASEVAC, emergency, task, TAKTALK, raw detail. Contact / group / status on V1; callsign / team / role / lat-lon on V2.

Firmware ≥ 2.8.0 speaks V2. Older radios use V1 PLI/chat, and generic CoT on the forwarder port.

Compressed V2 (zstd dictionary id 0 or 1) is not unpacked here; `decode_v2` raises unless `flags=0xFF`.

## Methods

- `encode` / `encode_v1` — `TAKPacket`
- `send` / `send_v1` / `send_chat` / `send_pli` — port 72
- `build_v2` / `encode_v2` / `wrap_v2` / `decode_v2` / `send_v2` — port 78
- `compress_cot` / `decompress_cot` / `send_cot` — port 257 (`cot:` XML string)
- `decode(payload:, portnum:)` — dispatches on port
- `help` / `authors`

`lat` / `lon` are decimal degrees (stored × 1e7). Pass a connected `serial_obj`, `bluetooth_obj`, or `tcp_obj`.

## V1 GeoChat and PLI

```ruby
Meshtastic::ATAK.send_chat(
  serial_obj: serial_obj,
  message: 'ATAK chat',
  to: 'ANDROID-aabbccdd',
  callsign: 'ALPHA',
  device_callsign: 'RADIO-1',
  team: :Cyan,
  role: :TeamMember,
  battery: 87
)

Meshtastic::ATAK.send_pli(
  serial_obj: serial_obj,
  lat: 37.7749,
  lon: -122.4194,
  altitude: 10,
  speed: 0,
  course: 90,
  callsign: 'ALPHA',
  team: :Cyan
)
```

## V2 typed events

```ruby
Meshtastic::ATAK.send_v2(serial_obj: serial_obj, message: 'v2 chat', callsign: 'ALPHA')

Meshtastic::ATAK.send_v2(
  serial_obj: serial_obj,
  callsign: 'ALPHA',
  lat: 37.7749,
  lon: -122.4194,
  aircraft: Meshtastic::AircraftTrack.new(icao: 'ABC123', flight: 'N1')
)

Meshtastic::ATAK.send_v2(serial_obj: serial_obj, shape: Meshtastic::DrawnShape.new(kind: :Kind_Circle, major_cm: 1000))
Meshtastic::ATAK.send_v2(serial_obj: serial_obj, marker: Meshtastic::Marker.new(kind: :Kind_Spot))
Meshtastic::ATAK.send_v2(serial_obj: serial_obj, route: Meshtastic::Route.new(prefix: 'R1'))
Meshtastic::ATAK.send_v2(serial_obj: serial_obj, casevac: Meshtastic::CasevacReport.new(title: 'CASEVAC'))
Meshtastic::ATAK.send_v2(serial_obj: serial_obj, emergency: Meshtastic::EmergencyAlert.new(type: :Type_Alert911))
Meshtastic::ATAK.send_v2(serial_obj: serial_obj, task: Meshtastic::TaskRequest.new(task_type: 'recon'))
Meshtastic::ATAK.send_v2(serial_obj: serial_obj, taktalk: Meshtastic::TakTalkMessage.new(text: 'hi', chatroom_id: 'room1'))
```

Receive V2:

```ruby
Meshtastic::Serial.subscribe(serial_obj: serial_obj, include: 'ATAK_PLUGIN') do |message|
  port = message.dig(:packet, :decoded, :portnum)
  payload = message.dig(:packet, :decoded, :payload)
  decoded = Meshtastic::ATAK.decode(payload: payload, portnum: port)
  p decoded
end
```

## Generic CoT (forwarder)

```ruby
Meshtastic::ATAK.send_cot(
  serial_obj: serial_obj,
  cot: '<event type="b-m-p-s-m" uid="marker-1"><point lat="37.77" lon="-122.41"/></event>'
)
```

Raises if zlib output exceeds `Meshtastic::Constants::DATA_PAYLOAD_LEN`. Multi-packet fountain (FTN) is not implemented; keep CoT small or use V2 typed payloads.

## Radio TAK module

Device role `TAK` / `TAK_TRACKER` and Module Config → TAK (`team` / `role`) are [Admin](admin.md) / [ModuleConfig](module-config.md), not this client:

```ruby
Meshtastic::ModuleConfig.get(serial_obj: serial_obj, module_config_type: :TAK_CONFIG)
```

## Related

- [Meshtastic::ModuleConfig](module-config.md)
- [Generated protobuf types](protobufs.md)
- [TAK wire formats](https://meshtastic.org/docs/software/apple/developer/tak-protocol/)
