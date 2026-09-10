# Meshtastic::RTTTL

Ringtone helpers. `encode` builds `RTTTLConfig`. `set` / `get` go through [Admin](admin.md) (`set_ringtone_message` / `get_ringtone_request`).

## Methods

- `encode(ringtone:)`
- `set(serial_obj:, ringtone:)`
- `get(serial_obj:)`
- `help` / `authors`

## Example

```ruby
Meshtastic::RTTTL.set(
  serial_obj: serial_obj,
  ringtone: 'Mario:d=4,o=5,b=125:16e6'
)
Meshtastic::RTTTL.get(serial_obj: serial_obj)
```

## Related

- [Meshtastic::Admin](admin.md)
