# Meshtastic::TCP

Same framed Stream API as [Serial](serial.md), over TCP. Firmware default port is `4403`. Use `tcp_obj:` instead of `serial_obj:`. Internally reuses Serial’s RX thread and framing.

## Methods

- `connect(host:, port:, socket:, want_config:, debug_out:)` — `host` default `127.0.0.1`, `port` default `4403`. `socket:` is for tests.
- `wait_for_config`
- `send_text` / `send_data` / `send_to_radio`
- `recv_from_radio` / `drain_from_radio`
- `subscribe`
- `disconnect`
- `help` / `authors`

## Send / receive

```ruby
require 'meshtastic'

tcp_obj = nil
begin
  tcp_obj = Meshtastic::TCP.connect(host: '192.0.2.10', port: 4403)
  Meshtastic::TCP.wait_for_config(tcp_obj: tcp_obj, timeout: 10)
  Meshtastic::TCP.send_text(
    tcp_obj: tcp_obj,
    to: '!ffffffff',
    channel: 0,
    text: 'Hello over TCP!'
  )
  Meshtastic::TCP.subscribe(tcp_obj: tcp_obj, include: 'TEXT_MESSAGE_APP') do |message|
    puts message.dig(:packet, :decoded, :payload)
  end
ensure
  Meshtastic::TCP.disconnect(tcp_obj: tcp_obj)
end
```

Enable TCP in radio network settings. Feature modules accept `tcp_obj:` the same way as `serial_obj:`.

## Related

- [Meshtastic::Serial](serial.md)
- [Meshtastic::Admin](admin.md)
