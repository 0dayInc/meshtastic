# Meshtastic::Admin::Config

Admin get/set for radio `Meshtastic::Config` sections. The generated protobuf remains `Meshtastic::Config`.

## Methods

- `get(config_type:)` — default `:DEVICE_CONFIG`
- `set(config:)`
- Named getters: `get_device`, `get_position`, `get_power`, `get_network`, `get_display`, `get_lora`, `get_bluetooth`, `get_security`, `get_sessionkey`, `get_device_ui`
- `set_device(device:)`, `set_lora(lora:)`
- `help` / `authors`

`config_type` values: `:DEVICE_CONFIG`, `:POSITION_CONFIG`, `:POWER_CONFIG`, `:NETWORK_CONFIG`, `:DISPLAY_CONFIG`, `:LORA_CONFIG`, `:BLUETOOTH_CONFIG`, `:SECURITY_CONFIG`, `:SESSIONKEY_CONFIG`, `:DEVICEUI_CONFIG`.

## Example

```ruby
Meshtastic::Admin::Config.get_lora(serial_obj: serial_obj)

config = Meshtastic::Config.new
config.device = Meshtastic::Config::DeviceConfig.new(role: :CLIENT)
Meshtastic::Admin::Config.set(serial_obj: serial_obj, config: config)
```

## Related

- [Meshtastic::Admin](admin.md)
- [Meshtastic::Admin::Channel](admin-channel.md)
