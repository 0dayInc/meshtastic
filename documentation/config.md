# Meshtastic::Config

Reopens the generated `Meshtastic::Config` protobuf class. Get/set go through [Admin](admin.md).

## Methods

- `get(serial_obj:, config_type: :DEVICE_CONFIG)`
- `set(serial_obj:, config:)` — `config` is a `Meshtastic::Config`
- `help` / `authors`

Protobuf oneofs include `device`, `position`, `power`, `network`, `display`, `lora`, `bluetooth`, `security`, `sessionkey`, `device_ui`.

## Example

```ruby
Meshtastic::Config.get(serial_obj: serial_obj, config_type: :LORA_CONFIG)

config = Meshtastic::Config.new
config.device = Meshtastic::Config::DeviceConfig.new(role: :CLIENT)
Meshtastic::Config.set(serial_obj: serial_obj, config: config)
```

`config_type` list: [Admin](admin.md).

## Related

- [Meshtastic::Admin](admin.md)
- [Meshtastic::ModuleConfig](module-config.md)
- [Meshtastic::Localonly](localonly.md)
