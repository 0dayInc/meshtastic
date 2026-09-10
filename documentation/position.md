# Meshtastic::Position

Reopens the generated `Meshtastic::Position` protobuf class. Sends `POSITION_APP` (port 3). Latitude/longitude are scaled by 1e7.

Do not define class methods named `send` or `encode` on this class. Use `transmit` and `build`.

## Methods

- `build(lat:, lon:, altitude:, time:)`
- `transmit` — deliver `POSITION_APP`
- `help` / `authors`

## Example

```ruby
Meshtastic::Position.transmit(
  serial_obj: serial_obj,
  lat: 37.7749,
  lon: -122.4194,
  altitude: 10
)

pos = Meshtastic::Position.build(lat: 37.7749, lon: -122.4194)
# pos.latitude_i == 377749000
```

Same kwargs as other radio sends: `to:`, `channel:`, `want_ack:`, plus `bluetooth_obj:` / `tcp_obj:`.

Protobuf fields also include `location_source`, `ground_speed`, `sats_in_view`, `precision_bits`, and related GPS metadata. See [protobufs.md](protobufs.md).

## Related

- [Meshtastic::Telemetry](telemetry.md)
- [Meshtastic::MeshInterface](mesh-interface.md)
