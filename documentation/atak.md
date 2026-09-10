# Meshtastic::ATAK

Encodes `Meshtastic::TAKPacket` and sends it on `ATAK_PLUGIN` (port 72).

## Methods

- `encode(is_compressed:, chat:, message:)` — `message:` builds a `GeoChat`
- `send`
- `help` / `authors`

## Example

```ruby
Meshtastic::ATAK.send(
  serial_obj: serial_obj,
  message: 'ATAK chat'
)

packet = Meshtastic::ATAK.encode(message: 'ATAK chat')
packet.chat.message # => "ATAK chat"
```

Related protobufs: `TAKPacket`, `GeoChat`, `Contact`, `Group`, `PLI`, `TAKPacketV2`. See [protobufs.md](protobufs.md).

## Related

- [Meshtastic::ModuleConfig](module-config.md) (`:TAK_CONFIG`)
