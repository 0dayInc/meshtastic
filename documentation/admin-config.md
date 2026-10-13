# Meshtastic::Admin::Config

Admin requests and writes for every section in the bundled `Meshtastic::Config` protobuf. Public methods take a single options Hash; `help` describes the options. The generated protobuf remains `Meshtastic::Config`.

## Operations

| Section | Read | Write | Value type |
| --- | --- | --- | --- |
| Device | `get_device` | `set_device(device:)` | `Config::DeviceConfig` or field Hash |
| Position | `get_position` | `set_position(position:)` | `Config::PositionConfig` or field Hash |
| Power | `get_power` | `set_power(power:)` | `Config::PowerConfig` or field Hash |
| Network | `get_network` | `set_network(network:)` | `Config::NetworkConfig` or field Hash |
| Display | `get_display` | `set_display(display:)` | `Config::DisplayConfig` or field Hash |
| LoRa | `get_lora` | `set_lora(lora:)` | `Config::LoRaConfig` or field Hash |
| Bluetooth | `get_bluetooth` | `set_bluetooth(bluetooth:)` | `Config::BluetoothConfig` or field Hash |
| Security | `get_security` | `set_security(security:)` | `Config::SecurityConfig` or field Hash |
| Session key | `get_sessionkey` | Request-only; writes raise `ArgumentError` | Empty `Config::SessionkeyConfig` placeholder |
| Device UI | `get_device_ui` | `set_device_ui(device_ui:)` | `Meshtastic::DeviceUIConfig` or field Hash |

- `get(config_type:)` is the raw ConfigType request (default `:DEVICE_CONFIG`). Supported types are `:DEVICE_CONFIG`, `:POSITION_CONFIG`, `:POWER_CONFIG`, `:NETWORK_CONFIG`, `:DISPLAY_CONFIG`, `:LORA_CONFIG`, `:BLUETOOTH_CONFIG`, `:SECURITY_CONFIG`, `:SESSIONKEY_CONFIG`, and `:DEVICEUI_CONFIG`.
- `set(config:)` accepts a `Meshtastic::Config` with exactly one selected section; an absent/empty config is rejected before transmission. All fields of the section, including nested/repeated fields, are supported by the generated protobuf, not a hand-picked subset.
- Device UI uses **`get_ui_config_request` / `store_ui_config`**, not the firmware's no-op Config device-UI handling. Generic `set` also routes a `device_ui` section correctly. The raw `get(config_type: :DEVICEUI_CONFIG)` remains a raw enum request; use `get_device_ui` for useful UI data.
- `SessionkeyConfig` is empty and request-only. The authorization bytes come from **`AdminMessage.session_passkey`**, not the Config payload. Both `set_sessionkey` and generic `set` reject this non-writable section.
- `help` / `authors` provide usage and attribution.

ModuleConfig is a different protobuf: use `Admin.get_module_config` / `Admin.set_module_config` for MQTT, telemetry, and other module configuration.

## Transport and authorization

Read/write helpers pass through Admin options, including `transport_obj: connection`, `to`, `from`, numeric transport `channel`, `want_ack`, `want_response`, `hop_limit`, and `session_passkey`. Use a supported connected transport. Session authentication and remote-node routing follow [Admin](admin.md).

For the section getters/setters above, a return value means transport submission, **not confirmed persistence**. These methods inherit Admin's automatic remote session-key acquisition, but do not wait for write acknowledgments or read settings back. Obtain the prior configuration, edit it, write, and request it again to confirm; configuration writes replace a whole section rather than patching only non-default fields. Omitting a field in a Hash can reset that setting to its protobuf default. Firmware version and hardware determine which fields are applied, and writes may reboot/disconnect the node.

## Example

```ruby
Meshtastic::Admin::Config.get_lora(transport_obj: connection)

# Supply the full desired section; prefer editing the returned protobuf.
Meshtastic::Admin::Config.set_position(
  transport_obj: connection,
  position: Meshtastic::Config::PositionConfig.new(position_broadcast_secs: 900)
)

Meshtastic::Admin::Config.set_device_ui(
  transport_obj: connection,
  device_ui: Meshtastic::DeviceUIConfig.new
)
```

Ruby protobuf's `display` reader collides with `Object#display`; inspect `config['display']`, not `config.display`. Do not log configuration objects: network/security settings and session passkeys can contain secrets.

## Signature policy and receive-only read/modify/readback

Two helpers perform **fresh get → single set → fresh get**, rather than replacing a whole section with defaults:

```ruby
result = Meshtastic::Admin::Config.set_packet_signature_policy(
  transport_obj: connection,
  policy: :PACKET_SIGNATURE_POLICY_BALANCED,
  timeout: 10
)

result = Meshtastic::Admin::Config.set_receive_only(
  transport_obj: connection,
  enabled: true, # writes LoRaConfig.tx_enabled = false; false re-enables TX
  timeout: 10
)
```

- `policy:` accepts the known `Config::SecurityConfig::PacketSignaturePolicy` symbols (`PACKET_SIGNATURE_POLICY_COMPATIBLE`, `PACKET_SIGNATURE_POLICY_BALANCED`, `PACKET_SIGNATURE_POLICY_STRICT`) or their known integer values. Unknown enums fail before any request. Compatible accepts unsigned traffic, balanced rejects unsigned signable broadcasts from previously signing nodes, strict requires authenticated traffic; strict can exclude older nodes.
- Both require a radio receive queue; MQTT is unsupported. Receive-only is deliberately restricted to the **connected local node**: disabling a remote node's radio TX would prevent reliable remote readback and recovery. This is LoRa TX disablement, not a new firmware role or a host-side packet filter.
- Current section fields are copied and only the requested field is changed. Security readback may contain private keys locally; do not log the returned data. Pinned firmware redacts remote private-key readback and preserves the existing identity keypair on a key-omitting security write.
- The return value contains `acknowledgment:` (the setter's Admin result), `readback:` (the final correlated Admin result), `matched:` (whether the requested field matches), and `reboot_requested: false`. A firmware build without signature support may normalize the policy to compatible; `matched: false` exposes that instead of claiming success. Inspect the returned section for other firmware-normalized changes.
- Helpers always wait and generate a fresh ID for each request, irrespective of supplied `wait`/`request_id`. `timeout` applies to each request. Pause other queue consumers throughout the sequence; do not run concurrent configuration editors.
- No explicit reboot, implicit commit, retry, or mutation replay is issued. **Firmware itself can reboot or disable BLE on a section write**, so a timeout/disconnect is not evidence of rollback. Reconnect and issue `Admin.request(get_config_request: :SECURITY_CONFIG)` or `:LORA_CONFIG` before deciding what to do next. `matched` is current readback, not post-reboot persistence or host cryptographic verification. An already-open firmware edit transaction remains the caller's responsibility.

These helpers are pinned to **v2.8.1.8e6a88d**: [config.proto](https://github.com/meshtastic/protobufs/blob/8f97d66a63ce10cfb12f94203e361691647f5ad3/meshtastic/config.proto) and [AdminModule.cpp](https://github.com/meshtastic/firmware/blob/8e6a88d06f44cad26f1e8d7cd402939ccacb9b4c/src/modules/AdminModule.cpp). Offline framing/readback tests establish host behavior, not live firmware application.

## Protocol evidence

- [Official Config schema](https://github.com/meshtastic/protobufs/blob/master/meshtastic/config.proto): all ten variants and request-only SessionkeyConfig.
- [Official Admin schema](https://github.com/meshtastic/protobufs/blob/master/meshtastic/admin.proto): ConfigType and dedicated UI operations.
- [Official firmware AdminModule](https://github.com/meshtastic/firmware/blob/master/src/modules/AdminModule.cpp): `handleSetConfig` / config request handling mark device-UI Config operations as no-ops and point to the dedicated handlers.

Related: [Admin](admin.md), [Channel](admin-channel.md).
