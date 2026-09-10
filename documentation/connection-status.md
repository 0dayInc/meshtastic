# Meshtastic::ConnectionStatus

Decodes `Meshtastic::DeviceConnectionStatus`.

## Methods

- `decode(bytes)`
- `help` / `authors`

## Example

```ruby
status = Meshtastic::ConnectionStatus.decode(
  Meshtastic::DeviceConnectionStatus.new.to_proto
)
```

Related types: `WifiConnectionStatus`, `EthernetConnectionStatus`, `NetworkConnectionStatus`, `BluetoothConnectionStatus`, `SerialConnectionStatus`.

## Related

- [Generated protobuf types](protobufs.md)
