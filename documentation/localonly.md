# Meshtastic::Localonly

Decodes `LocalConfig` and `LocalModuleConfig` (full config blobs stored on the client).

## Methods

- `decode_config(bytes)`
- `decode_module_config(bytes)`
- `help` / `authors`

## Example

```ruby
Meshtastic::Localonly.decode_config(Meshtastic::LocalConfig.new.to_proto)
Meshtastic::Localonly.decode_module_config(Meshtastic::LocalModuleConfig.new.to_proto)
```

## Related

- [Meshtastic::Config](config.md)
- [Meshtastic::ModuleConfig](module-config.md)
