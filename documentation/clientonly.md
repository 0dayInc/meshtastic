# Meshtastic::Clientonly

Client-side `Meshtastic::DeviceProfile` encode/decode (`clientonly.proto`).

## Methods

- `encode(long_name:, short_name:)`
- `decode(bytes)`
- `help` / `authors`

## Example

```ruby
profile = Meshtastic::Clientonly.encode(long_name: 'Node', short_name: 'N1')
profile.long_name # => "Node"
Meshtastic::Clientonly.decode(profile.to_proto)
```

## Related

- [Meshtastic::Admin](admin.md) (`set_owner`)
