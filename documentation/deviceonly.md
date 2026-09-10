# Meshtastic::Deviceonly

Decodes device-only snapshots: `DeviceState` and `NodeDatabase`.

## Methods

- `decode_state(bytes)`
- `decode_nodedb(bytes)`
- `help` / `authors`

## Example

```ruby
state = Meshtastic::Deviceonly.decode_state(Meshtastic::DeviceState.new.to_proto)
nodedb = Meshtastic::Deviceonly.decode_nodedb(Meshtastic::NodeDatabase.new.to_proto)
```

Related types: `PositionLite`, `UserLite`, `NodeInfoLite`, `ChannelFile`, `BackupPreferences`.

## Related

- [Meshtastic::Localonly](localonly.md)
