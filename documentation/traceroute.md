# Meshtastic::Traceroute

Sends `RouteDiscovery` on `TRACEROUTE_APP` (port 70) with `want_response: true`.

## Methods

- `encode(route:)` — optional hop list
- `send(serial_obj:, to:, ...)`
- `help` / `authors`

## Example

```ruby
Meshtastic::Traceroute.send(
  serial_obj: serial_obj,
  to: '!aabbccdd',
  want_ack: true
)

Meshtastic::Serial.subscribe(serial_obj: serial_obj, include: 'TRACEROUTE_APP') do |message|
  p message.dig(:packet, :decoded)
end
```

## Related

- [Meshtastic::Serial](serial.md)
- Protobuf: `RouteDiscovery`, `Routing` in [protobufs.md](protobufs.md)
