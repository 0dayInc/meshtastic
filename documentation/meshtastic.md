# Meshtastic (top-level)

`require 'meshtastic'` loads protobufs, autoloads client modules, and reopens a few generated classes (`Channel`, `Config`, `ModuleConfig`, `Paxcount`, `Position`, `Telemetry`).

## Constants

| Name | Value | Meaning |
| --- | --- | --- |
| `NODELESS_WANT_CONFIG_ID` | `69420` | Config handshake id when `no_nodes` is set |
| `START1` | `0x94` | UART/TCP frame magic |
| `START2` | `0xC3` | UART/TCP frame magic |
| `HEADER_LEN` | `4` | Frame header bytes |
| `MAX_TO_FROM_RADIO_SIZE` | `512` | Max ToRadio/FromRadio body |
| `VERSION` | gem version string | `Meshtastic::VERSION` |

## Methods

### `Meshtastic.help`

Returns sorted constants in the namespace (not printed usage).

```ruby
require 'meshtastic'
Meshtastic.help
# => [:ADMIN_APP, :ATAK, :Admin, :AdminMessage, ...]
```

### `Meshtastic.deliver_data`

Routes a `Meshtastic::Data` payload to a connected radio.

```ruby
Meshtastic.deliver_data(
  serial_obj: serial_obj,   # or bluetooth_obj: / tcp_obj: / mqtt_obj:
  data: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP, payload: 'hi'),
  port_num: Meshtastic::PortNum::TEXT_MESSAGE_APP
)
```

Raises `ArgumentError` unless `data` is a `Meshtastic::Data` and one of `serial_obj`, `bluetooth_obj`, `tcp_obj`, or `mqtt_obj` is present.

## Related

- [Transports](README.md#transports)
- [Generated protobuf types](protobufs.md)
