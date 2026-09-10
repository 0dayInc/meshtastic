# Meshtastic::Xmodem

Builds `Meshtastic::XModem` packets (`xmodem.proto`). Distinct from the generated class `Meshtastic::XModem`.

## Methods

- `encode(control:, seq:, buffer:)`
- `help` / `authors`

`control` includes `:SOH` and other `XModem::Control` values.

## Example

```ruby
packet = Meshtastic::Xmodem.encode(control: :SOH, seq: 1, buffer: 'A')
packet.control # => :SOH
packet.seq     # => 1
```

## Related

- [Generated protobuf types](protobufs.md)
