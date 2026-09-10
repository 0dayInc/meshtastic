# Meshtastic::Admin::Channel

Admin get/set for mesh channels. The generated protobuf remains `Meshtastic::Channel`; this module talks to the node on `ADMIN_APP`.

Roles: `:PRIMARY`, `:SECONDARY`, `:DISABLED`.

## Methods

- `build_settings` — `ChannelSettings` (name, psk, uplink/downlink, AEAD)
- `build` — `Channel` (index, role, settings)
- `get(index:)` — `get_channel_request`
- `set` — `set_channel` with a Channel protobuf
- `help` / `authors`

Do not pass a Channel protobuf as MeshInterface `channel:` (that field is the numeric channel index). This module strips that key before send.

## Example

```ruby
settings = Meshtastic::Admin::Channel.build_settings(name: 'LongFast', uplink_enabled: true)
Meshtastic::Admin::Channel.set(
  serial_obj: serial_obj,
  index: 0,
  role: :PRIMARY,
  settings: settings
)
Meshtastic::Admin::Channel.get(serial_obj: serial_obj, index: 0)
```

## Related

- [Meshtastic::Admin](admin.md)
- [Meshtastic::Admin::Config](admin-config.md)
