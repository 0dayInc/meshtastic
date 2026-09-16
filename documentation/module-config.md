# Meshtastic::ModuleConfig

Reopens the generated `Meshtastic::ModuleConfig` protobuf class. Get/set module configuration via [Admin](admin.md).

## Methods

- `get(transport_obj:, module_config_type: :MQTT_CONFIG)`
- `set(transport_obj:, module_config:)`
- `help` / `authors`

`module_config_type` values include `:MQTT_CONFIG`, `:SERIAL_CONFIG`, `:STOREFORWARD_CONFIG`, `:TELEMETRY_CONFIG`, `:REMOTEHARDWARE_CONFIG`, `:CANNEDMSG_CONFIG`, `:AUDIO_CONFIG`, `:PAXCOUNTER_CONFIG`, `:NEIGHBORINFO_CONFIG`, `:DETECTIONSENSOR_CONFIG`, `:EXTNOTIF_CONFIG`, `:RANGETEST_CONFIG`, `:AMBIENTLIGHTING_CONFIG`, `:STATUSMESSAGE_CONFIG`, `:MESHBEACON_CONFIG`, `:TAK_CONFIG`, `:TRAFFICMANAGEMENT_CONFIG`.

Supply `transport_obj: connection` with an actual connected Serial, Bluetooth, TCP, or MQTT handle. These non-Admin wrappers also retain `serial_obj:`, `bluetooth_obj:`, `tcp_obj:`, and `mqtt_obj:` for existing callers, translating them internally to Admin's `transport_obj:`. Supply exactly one non-nil connection option; mixed aliases are rejected even when they refer to the same handle. Nil aliases are ignored, and caller options are not mutated.

Routing, validation, and automatic remote session-key acquisition follow [Admin](admin.md). Setters may wait for session acquisition, but their return value is transport submission, not confirmed persistence. MQTT requires an explicit authorized passkey for remote writes; these helpers do not add synchronous MQTT readback.

## Example

```ruby
Meshtastic::ModuleConfig.get(transport_obj: connection, module_config_type: :MQTT_CONFIG)

mod = Meshtastic::ModuleConfig.new
mod.mqtt = Meshtastic::ModuleConfig::MQTTConfig.new(enabled: true, address: 'mqtt.example.test')
Meshtastic::ModuleConfig.set(transport_obj: connection, module_config: mod)
```

## Related

- [Meshtastic::Admin](admin.md)
- [Meshtastic::Config](config.md)
