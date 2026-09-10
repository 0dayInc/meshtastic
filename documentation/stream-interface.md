# Meshtastic::StreamInterface

Abstract UART helper left from the Python client layout. Instantiating it raises unless a subclass sets `@stream` (or `no_proto: true`).

Use [Meshtastic::Serial](serial.md) for USB/UART.

```ruby
# raises: StreamInterface is now abstract (to update existing code use Meshtastic::Serial instead)
Meshtastic::StreamInterface.new
```

## Related

- [Meshtastic::Serial](serial.md)
- [Meshtastic::TCP](tcp.md)
