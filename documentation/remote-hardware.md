# Meshtastic::RemoteHardware

GPIO control on `REMOTE_HARDWARE_APP` (port 2) using `Meshtastic::HardwareMessage`.

## Methods

- `encode(type:, gpio_mask:, gpio_value:)`
- `send`
- `read_gpios(gpio_mask:)`
- `write_gpios(gpio_mask:, gpio_value:)`
- `watch_gpios(gpio_mask:)`
- `help` / `authors`

`type` values: `:UNSET`, `:WRITE_GPIOS`, `:WATCH_GPIOS`, `:GPIOS_CHANGED`, `:READ_GPIOS`, `:READ_GPIOS_REPLY`.

## Example

```ruby
Meshtastic::RemoteHardware.write_gpios(
  serial_obj: serial_obj,
  gpio_mask: 0x01,
  gpio_value: 0x01
)

Meshtastic::RemoteHardware.read_gpios(serial_obj: serial_obj, gpio_mask: 0x01)
Meshtastic::RemoteHardware.watch_gpios(serial_obj: serial_obj, gpio_mask: 0x01)
```

Enable the Remote Hardware module on the node and only drive pins the firmware exposes.

## Related

- [Meshtastic::ModuleConfig](module-config.md)
