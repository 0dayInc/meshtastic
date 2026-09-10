# Meshtastic::Apponly

App-side channel export: `Meshtastic::ChannelSet` (from `apponly.proto`).

## Methods

- `encode(settings:, lora_config:)`
- `decode(bytes)`
- `help` / `authors`

## Example

```ruby
set = Meshtastic::Apponly.encode(
  settings: [Meshtastic::ChannelSettings.new(name: 'LongFast')]
)
round_trip = Meshtastic::Apponly.decode(set.to_proto)
```

## Related

- [Meshtastic::Channel](channel.md)
