# Meshtastic::Telemetry

Reopens the generated `Meshtastic::Telemetry` protobuf class. Requests metrics on `TELEMETRY_APP` (port 67) with `want_response: true`.

Use `build` / `request`, not `send` / `encode`.

## Methods

- `build(time:)`
- `request(serial_obj:, to:, ...)`
- `help` / `authors`

## Example

```ruby
Meshtastic::Telemetry.request(
  serial_obj: serial_obj,
  to: '!aabbccdd'
)

Meshtastic::Serial.subscribe(serial_obj: serial_obj, include: 'TELEMETRY_APP') do |message|
  tel = Meshtastic::Telemetry.decode(message.dig(:packet, :decoded, :payload).to_s) rescue nil
  p tel&.device_metrics
end
```

Incoming payloads may include `device_metrics`, `environment_metrics`, `air_quality_metrics`, `power_metrics`, `local_stats`, `health_metrics`, `host_metrics`, `traffic_management_stats`, `soil_water_metrics`.

## Related

- [Meshtastic::Position](position.md)
- [Meshtastic::Paxcount](paxcount.md)
