# Meshtastic Ruby documentation

Usage for every constant in the `Meshtastic` namespace lives here. The root [README](../README.md) is install, expectations, and contributing only.

`require 'meshtastic'` then `Meshtastic.help` lists loaded constants. Each first-class API module also has `.help` and `.authors`.

Examples use placeholder addresses only:

- Serial port: `/dev/ttyACM0`
- BLE: `AA:BB:CC:DD:EE:FF`
- Mesh node: `!aabbccdd` (destination), `!11223344` (local)
- MQTT sample node: `!c0ffee00`
- TCP radio: `192.0.2.10`
- Broadcast: `!ffffffff` (protocol all-nodes address)

## Transports

- [Meshtastic::MQTT](mqtt.md)
- [Meshtastic::Serial](serial.md)
- [Meshtastic::Bluetooth](bluetooth.md)
- [Meshtastic::Bluetooth::BlueZ](bluetooth-bluez.md)
- [Meshtastic::TCP](tcp.md)

Feature modules send protobufs over Serial, Bluetooth, or TCP via `Meshtastic.deliver_data`. Pass `serial_obj:`, `bluetooth_obj:`, or `tcp_obj:`. MQTT encrypts on the host; the radio encrypts on the other three.

Do not open Serial and Bluetooth to the same radio at once. Always `disconnect` in `ensure`.

## Feature modules

- [Meshtastic::Admin](admin.md)
- [Meshtastic::Channel](channel.md)
- [Meshtastic::Config](config.md)
- [Meshtastic::ModuleConfig](module-config.md)
- [Meshtastic::Position](position.md)
- [Meshtastic::Telemetry](telemetry.md)
- [Meshtastic::Traceroute](traceroute.md)
- [Meshtastic::RemoteHardware](remote-hardware.md)
- [Meshtastic::Storeforward](storeforward.md)
- [Meshtastic::ATAK](atak.md)
- [Meshtastic::Paxcount](paxcount.md)
- [Meshtastic::Cannedmessages](cannedmessages.md)
- [Meshtastic::RTTTL](rtttl.md)
- [Meshtastic::Portnums](portnums.md)
- [Meshtastic::Apponly](apponly.md)
- [Meshtastic::Clientonly](clientonly.md)
- [Meshtastic::Deviceonly](deviceonly.md)
- [Meshtastic::Localonly](localonly.md)
- [Meshtastic::ConnectionStatus](connection-status.md)
- [Meshtastic::Xmodem](xmodem.md)

## Internals

- [Meshtastic (top-level)](meshtastic.md)
- [Meshtastic::MeshInterface](mesh-interface.md)
- [Meshtastic::StreamInterface](stream-interface.md)
- [Meshtastic::Util](util.md)
- [Generated protobuf types](protobufs.md)

Protobuf message classes that this gem reopens (`Channel`, `Config`, `Position`, `Telemetry`, `ModuleConfig`, `Paxcount`) must not define class methods named `send` or `encode` (those belong to protobuf). Use `get`/`set`, `transmit`, `build`, or `request` instead.
