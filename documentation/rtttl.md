# Meshtastic::RTTTL

Ringtone helpers. `encode` builds `RTTTLConfig`. `set` / `get` go through [Admin](admin.md) (`set_ringtone_message` / `get_ringtone_request`).

## Methods

- `encode(ringtone:)`
- `set(transport_obj:, ringtone:)`
- `get(transport_obj:)`
- `help` / `authors`

Supply `transport_obj: connection` with an actual connected Serial, Bluetooth, TCP, or MQTT handle. These non-Admin wrappers also retain `serial_obj:`, `bluetooth_obj:`, `tcp_obj:`, and `mqtt_obj:` for existing callers, translating them internally to Admin's `transport_obj:`. Supply exactly one non-nil connection option; mixed aliases are rejected even when they refer to the same handle. Nil aliases are ignored, and caller options are not mutated.

Routing, validation, and automatic remote session-key acquisition follow [Admin](admin.md). Setters may wait for session acquisition, but their return value is transport submission, not confirmed persistence. MQTT requires an explicit authorized passkey for remote writes; these helpers do not add synchronous MQTT readback.

## Example

```ruby
Meshtastic::RTTTL.set(
  transport_obj: connection,
  ringtone: 'Mario:d=4,o=5,b=125:16e6'
)
Meshtastic::RTTTL.get(transport_obj: connection)
```

## Related

- [Meshtastic::Admin](admin.md)
