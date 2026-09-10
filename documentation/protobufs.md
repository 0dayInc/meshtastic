# Generated protobuf types

These classes and enums come from `lib/meshtastic/*_pb.rb` (Meshtastic protobufs via `grpc_tools_ruby_protoc`). They live in the `Meshtastic` namespace. Typical API:

```ruby
msg = Meshtastic::User.new(long_name: 'Node', short_name: 'N1')
bytes = msg.to_proto
again = Meshtastic::User.decode(bytes)
msg.to_h
```

Enums: `Meshtastic::PortNum::TEXT_MESSAGE_APP`, `Meshtastic::PortNum.lookup(1)`, `Meshtastic::PortNum.resolve(:TEXT_MESSAGE_APP)`.

A few generated **classes** are reopened with extra class methods: `Channel`, `Config`, `ModuleConfig`, `Paxcount`, `Position`, `Telemetry`. Do not name those extras `send` or `encode`.

First-class wrappers for many of these types: [documentation index](README.md).

## admin.proto

- Messages: `AdminMessage`, `AdminMessage::InputEvent`, `AdminMessage::OTAEvent`, `LockdownAuth`, `HamParameters`, `NodeRemoteHardwarePinsResponse`, `SharedContact`, `KeyVerificationAdmin`, `SensorConfig`, `SCD4X_config`, `SEN5X_config`, `SEN6X_config`, `SCD30_config`, `SHTXX_config`, `DS248X_config`, `AS3935_config`
- Enums: `AdminMessage::ConfigType`, `AdminMessage::ModuleConfigType`, `AdminMessage::BackupLocation`, `KeyVerificationAdmin::MessageType`, `OTAMode`

See [Admin](admin.md).

## apponly.proto

- `ChannelSet` — [Apponly](apponly.md)

## atak.proto

- Messages: `TAKPacket`, `GeoChat`, `Group`, `Status`, `Contact`, `PLI`, `AircraftTrack`, `CotGeoPoint`, `DrawnShape`, `Marker`, `RangeAndBearing`, `Route`, `Route::Link`, `CasevacReport`, `ZMistEntry`, `EmergencyAlert`, `TaskRequest`, `TAKEnvironment`, `SensorFov`, `TakTalkMessage`, `TakTalkRoomData`, `Marti`, `TAKPacketV2`
- Enums: `GeoChat::ReceiptType`, `DrawnShape::Kind`, `DrawnShape::StyleMode`, `Marker::Kind`, `Route::Method`, `Route::Direction`, `CasevacReport::Precedence`, `CasevacReport::HlzMarking`, `CasevacReport::Security`, `EmergencyAlert::Type`, `TaskRequest::Priority`, `TaskRequest::Status`, `SensorFov::SensorType`, `Team`, `MemberRole`, `CotHow`, `CotType`, `GeoPointSource`

See [ATAK](atak.md).

## cannedmessages.proto

- `CannedMessageModuleConfig` — [Cannedmessages](cannedmessages.md)

## channel.proto

- `ChannelSettings`, `ModuleSettings`, `Channel`, `Channel::Role` — [Channel](channel.md)

## clientonly.proto

- `DeviceProfile` — [Clientonly](clientonly.md)

## config.proto

- `Config` and nested `DeviceConfig`, `PositionConfig`, `PowerConfig`, `NetworkConfig`, `DisplayConfig`, `LoRaConfig`, `BluetoothConfig`, `SecurityConfig`, `SessionkeyConfig` plus their enums — [Config](config.md)

## connection_status.proto

- `DeviceConnectionStatus`, `WifiConnectionStatus`, `EthernetConnectionStatus`, `NetworkConnectionStatus`, `BluetoothConnectionStatus`, `SerialConnectionStatus` — [ConnectionStatus](connection-status.md)

## device_ui.proto

- `DeviceUIConfig`, `NodeFilter`, `NodeHighlight`, `GeoPoint`, `Map`
- Enums: `DeviceUIConfig::GpsCoordinateFormat`, `CompassMode`, `Theme`, `Language`

No dedicated wrapper; set via Admin `DEVICEUI_CONFIG` / `Config.device_ui`.

## deviceonly.proto / deviceonly_legacy.proto

- `PositionLite`, `UserLite`, `NodeInfoLite`, `DeviceState`, `NodePositionEntry`, `NodeTelemetryEntry`, `NodeEnvironmentEntry`, `NodeStatusEntry`, `NodeDatabase`, `ChannelFile`, `BackupPreferences`
- Legacy: `NodeInfoLite_Legacy`, `NodeDatabase_Legacy`

See [Deviceonly](deviceonly.md).

## interdevice.proto

- `FileTransfer`, `DirectoryListing`, `I2CTransaction`, `SdCardInfo`, `I2CResult`, `InterdeviceMessage`
- Enums: `SdCardInfo::CardType`, `SdCardInfo::FatType`, `I2CResult::Status`, `InterdeviceVersion`, `FileOperation`, `FileStatus`, `SdCommand`

No dedicated wrapper. Encode/decode the generated classes directly.

## localonly.proto

- `LocalConfig`, `LocalModuleConfig` — [Localonly](localonly.md)

## lorawan_bridge.proto

- `LoRaWANBridge` plus nested `Uplink`, `Downlink`, `PayloadChunk`, `TxResult`

No dedicated wrapper. Port `LORAWAN_BRIDGE` (75).

## mesh_beacon.proto

- `MeshBeacon` — port `MESH_BEACON_APP` (37)

## mesh.proto

Core radio types:

- `Position` ([Position](position.md)), `User`, `RouteDiscovery` ([Traceroute](traceroute.md)), `Routing`, `Data`, `KeyVerification`, `StoreForwardPlusPlus`, `RemoteShell`, `BoundingBox`, `Waypoint`, `StatusMessage`, `MqttClientProxyMessage`, `MeshPacket`, `NodeInfo`, `MyNodeInfo`, `LogRecord`, `QueueStatus`, `FromRadio`, `LockdownStatus`, `ClientNotification`, `KeyVerificationNumberInform`, `KeyVerificationNumberRequest`, `KeyVerificationFinal`, `DuplicatedPublicKey`, `LowEntropyKey`, `FileInfo`, `ToRadio`, `Compressed`, `NeighborInfo`, `Neighbor`, `DeviceMetadata`, `LoRaPresetGroup`, `LoRaRegionPresets`, `LoRaRegionPresetMap`, `Heartbeat`, `NodeRemoteHardwarePin`, `ChunkedPayload`, `resend_chunks`, `ChunkedPayloadResponse`
- Enums: `HardwareModel`, `Constants`, `CriticalErrorCode`, `FirmwareEdition`, `ExcludedModules`, plus nested enums on Position, Routing, MeshPacket, LogRecord, LockdownStatus, RemoteShell, StoreForwardPlusPlus

Serial/TCP frames carry `ToRadio` / `FromRadio`. MQTT publishes `ServiceEnvelope` wrapping `MeshPacket`.

## module_config.proto

- `ModuleConfig` and nested MQTT/Serial/StoreForward/Telemetry/… configs — [ModuleConfig](module-config.md)
- `RemoteHardwarePin`, `RemoteHardwarePinType`

## mqtt.proto

- `ServiceEnvelope`, `MapReport` — [MQTT](mqtt.md)

## paxcount.proto

- `Paxcount` — [Paxcount](paxcount.md)

## portnums.proto

- `PortNum` — [Portnums](portnums.md)

## powermon.proto

- `PowerMon`, `PowerStressMessage` (and nested enums)

No dedicated wrapper. Port `POWERSTRESS_APP` (74).

## remote_hardware.proto

- `HardwareMessage`, `HardwareMessage::Type` — [RemoteHardware](remote-hardware.md)

## rtttl.proto

- `RTTTLConfig` — [RTTTL](rtttl.md)

## serial_hal.proto

- `SerialHalCommand`, `SerialHalResponse`

GPIO serial HAL, not USB CDC. See [Serial](serial.md) for the USB Stream API.

## storeforward.proto

- `StoreAndForward` plus `Statistics`, `History`, `Heartbeat`, `RequestResponse` — [Storeforward](storeforward.md)

## telemetry.proto

- `Telemetry` ([Telemetry](telemetry.md)), `DeviceMetrics`, `EnvironmentMetrics`, `SoilWaterMetrics`, `PowerMetrics`, `AirQualityMetrics`, `LocalStats`, `TrafficManagementStats`, `HealthMetrics`, `HostMetrics`, `Nau7802Config`, `AS3935Config`, `SEN5XState`, `SEN6XState`, `TelemetrySensorType`

## xmodem.proto

- `XModem`, `XModem::Control` — [Xmodem](xmodem.md)

## nanopb

`require 'nanopb_pb'` is loaded with the gem. It is not a `Meshtastic::` module.

## Example: inspect a type

```ruby
require 'meshtastic'

Meshtastic::AdminMessage.descriptor.each { |f| puts f.name }
Meshtastic::PortNum.constants.sort
user = Meshtastic::User.new(long_name: 'Node', short_name: 'N1')
Meshtastic::User.decode(user.to_proto)
```
