# Meshtastic::Admin

Builds `Meshtastic::AdminMessage` and sends it on `ADMIN_APP` (port 6) through [Meshtastic.deliver_data](meshtastic.md). Pass a connected `serial_obj`, `bluetooth_obj`, or `tcp_obj`.

Responses come back as `FromRadio` packets on the same transport (`subscribe` / `recv_from_radio`).

## Methods

- `encode` — copies matching keys onto an `AdminMessage`
- `send` — wrap and deliver (`want_response` default true)
- `reboot(seconds: 5)`
- `shutdown(seconds: 5)`
- `get_owner` / `set_owner(long_name:, short_name:, owner:)`
- `get_channel(index:)` / `set_channel(channel_settings:)`
- `get_config(config_type:)` / `set_config(config:)`
- `nodedb_reset`
- `help` / `authors`

`config_type` values: `:DEVICE_CONFIG`, `:POSITION_CONFIG`, `:POWER_CONFIG`, `:NETWORK_CONFIG`, `:DISPLAY_CONFIG`, `:LORA_CONFIG`, `:BLUETOOTH_CONFIG`, `:SECURITY_CONFIG`, `:SESSIONKEY_CONFIG`, `:DEVICEUI_CONFIG`.

Any other `AdminMessage` field can be passed to `send` / `encode` (for example `set_ringtone_message`, `get_module_config_request`).

## Examples

```ruby
require 'meshtastic'

serial_obj = Meshtastic::Serial.connect(block_dev: '/dev/ttyACM0')
Meshtastic::Serial.wait_for_config(serial_obj: serial_obj)

Meshtastic::Admin.set_owner(serial_obj: serial_obj, long_name: 'Node', short_name: 'N1')
Meshtastic::Admin.get_owner(serial_obj: serial_obj)
Meshtastic::Admin.get_config(serial_obj: serial_obj, config_type: :LORA_CONFIG)
Meshtastic::Admin.get_channel(serial_obj: serial_obj, index: 0)
Meshtastic::Admin.reboot(serial_obj: serial_obj, seconds: 5)
# Meshtastic::Admin.shutdown(serial_obj: serial_obj, seconds: 5)
# Meshtastic::Admin.nodedb_reset(serial_obj: serial_obj)
```

Raw field:

```ruby
Meshtastic::Admin.send(
  serial_obj: serial_obj,
  factory_reset_config: true
)
```

## Related

- [Meshtastic::Channel](channel.md)
- [Meshtastic::Config](config.md)
- [Meshtastic::ModuleConfig](module-config.md)
- [Meshtastic::RTTTL](rtttl.md)
