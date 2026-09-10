# Meshtastic::Serial

USB/UART Stream API. Framing is `[0x94][0xC3][len_hi][len_lo]` plus a `ToRadio` / `FromRadio` protobuf.

The radio applies channel crypto. Payloads go out decoded. `channel:` is the device channel index (usually `0`), not an MQTT hash.

## Setup

Use the USB CDC port (`/dev/ttyACM*` or `/dev/ttyUSB*`). Enable Radio Configuration → Security → Serial Console (`security.serial_enabled`). That is not Module Configuration → Serial (`TEXTMSG` / `PROTO` on GPIO). Keep “Override Console Serial Port” off.

Do not open Serial and Bluetooth to the same radio at once.

## Methods

- `connect(block_dev:, baud:, data_bits:, stop_bits:, parity:, debug_out:, want_config:)`
- `wait_for_config(serial_obj:, timeout:)` — raises `Timeout::Error` if handshake never completes
- `wake_up_device` — writes 32 × `START2`
- `request` — raw bytes
- `send_to_radio` — framed `ToRadio`
- `send_text` / `send_data`
- `recv_from_radio(timeout:)` — `0` polls, `nil` blocks, default `5`. Closed empty queue → `nil`. Unplug → `IOError`
- `drain_from_radio`
- `dump_stdout_data` / `flush_data` / `monitor_stdout` (`:proto` or `:console`)
- `subscribe` — blocking FromRadio loop
- `disconnect`
- `help` / `authors`

`send_text` / `send_data` return bytes written, not mesh delivery. `want_ack: true` asks for `ROUTING_APP` (`error_reason: NONE` means the local radio accepted the route). Incoming text is UTF-8 under `message[:packet][:decoded][:payload]`.

Call `wait_for_config` before using `my_node_num` or sending. Opening a port is not a completed handshake.

## Send / receive

```ruby
require 'meshtastic'

serial_obj = nil
begin
  serial_obj = Meshtastic::Serial.connect(block_dev: '/dev/ttyACM0', baud: 115_200)
  Meshtastic::Serial.wait_for_config(serial_obj: serial_obj, timeout: 10)
  puts "local node: !#{serial_obj[:my_node_num].to_s(16)}"

  Meshtastic::Serial.send_text(
    serial_obj: serial_obj,
    to: '!aabbccdd',       # or '!ffffffff' for the shared channel
    channel: 0,
    text: 'Hello over serial!',
    want_ack: true
  )

  Meshtastic::Serial.subscribe(
    serial_obj: serial_obj,
    include: 'TEXT_MESSAGE_APP'
  ) do |message|
    packet = message[:packet]
    puts "#{packet[:node_id_from]}: #{packet.dig(:decoded, :payload)}"
  end
ensure
  Meshtastic::Serial.disconnect(serial_obj: serial_obj)
end
```

Drive the loop yourself:

```ruby
from_radio = Meshtastic::Serial.recv_from_radio(serial_obj: serial_obj, timeout: 0)
msgs = Meshtastic::Serial.drain_from_radio(serial_obj: serial_obj, max: 256)
```

If `wait_for_config` times out, the USB path is up but the Stream API is not (wrong port, Serial Console disabled, or firmware not responding).

Default `block_dev` is `/dev/ttyUSB0`, baud `115200`, 8N1.

## Related

- [Meshtastic::TCP](tcp.md) (same framing)
- [Meshtastic::Bluetooth](bluetooth.md)
- [Meshtastic::Admin](admin.md)
