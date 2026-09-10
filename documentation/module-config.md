# Meshtastic::ModuleConfig

Reopens the generated `Meshtastic::ModuleConfig` protobuf class. Get/set module configuration via [Admin](admin.md).

## Methods

- `get(serial_obj:, module_config_type: :MQTT_CONFIG)`
- `set(serial_obj:, module_config:)`
- `help` / `authors`

`module_config_type` values include `:MQTT_CONFIG`, `:SERIAL_CONFIG`, `:STOREFORWARD_CONFIG`, `:TELEMETRY_CONFIG`, `:REMOTEHARDWARE_CONFIG`, `:CANNEDMSG_CONFIG`, `:AUDIO_CONFIG`, `:PAXCOUNTER_CONFIG`, `:NEIGHBORINFO_CONFIG`, `:DETECTIONSENSOR_CONFIG`, `:EXTNOTIF_CONFIG`, `:RANGETEST_CONFIG`, `:AMBIENTLIGHTING_CONFIG`, `:STATUSMESSAGE_CONFIG`, `:MESHBEACON_CONFIG`, `:TAK_CONFIG`, `:TRAFFICMANAGEMENT_CONFIG`.

## Example

```ruby
Meshtastic::ModuleConfig.get(serial_obj: serial_obj, module_config_type: :MQTT_CONFIG)

mod = Meshtastic::ModuleConfig.new
mod.mqtt = Meshtastic::ModuleConfig::MQTTConfig.new(enabled: true, address: 'mqtt.example.test')
Meshtastic::ModuleConfig.set(serial_obj: serial_obj, module_config: mod)
```

## Related

- [Meshtastic::Admin](admin.md)
- [Meshtastic::Config](config.md)
