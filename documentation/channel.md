# Meshtastic::Channel

Reopens the generated `Meshtastic::Channel` protobuf class with get/set helpers that call [Admin](admin.md).

This is a protobuf class, not a Ruby module. Do not add class methods named `send` or `encode`.

## Methods

- `get(serial_obj:, index:)` — `get_channel_request`
- `set(serial_obj:, channel:)` — `set_channel`
- `help` / `authors`

Also all protobuf instance fields: `index`, `settings` (`ChannelSettings`), `role` (`:DISABLED`, `:PRIMARY`, `:SECONDARY`).

## Example

```ruby
Meshtastic::Channel.get(serial_obj: serial_obj, index: 0)

settings = Meshtastic::ChannelSettings.new(name: 'LongFast', psk: "\x01")
channel = Meshtastic::Channel.new(index: 0, settings: settings, role: :PRIMARY)
Meshtastic::Channel.set(serial_obj: serial_obj, channel: channel)
```

Listen for `ADMIN_APP` replies on the same transport.

## Related

- [Meshtastic::Admin](admin.md)
- [Meshtastic::Apponly](apponly.md) (`ChannelSet`)
