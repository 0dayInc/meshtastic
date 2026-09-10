# Meshtastic::Paxcount

Reopens the generated `Meshtastic::Paxcount` protobuf class. Transmits `PAXCOUNTER_APP` (port 34).

Use `build` / `transmit`, not `send` / `encode`.

## Methods

- `build(wifi:, ble:, uptime:)`
- `transmit`
- `help` / `authors`

## Example

```ruby
Meshtastic::Paxcount.transmit(
  serial_obj: serial_obj,
  wifi: 3,
  ble: 2
)
```

## Related

- [Meshtastic::Telemetry](telemetry.md)
