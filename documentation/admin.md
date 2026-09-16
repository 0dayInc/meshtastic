# Meshtastic::Admin

Build and send `AdminMessage` on `ADMIN_APP` through a connected `serial_obj`, `bluetooth_obj`, `tcp_obj`, or `mqtt_obj`. These operations can change configuration, reboot, erase files, or reset a device. Sending is not confirmation of successful execution.

## Addressing and defaults

- Radio transports default `to` to their connected `my_node_num` and `from` to zero (the local PhoneAPI client). Complete the transport configuration handshake first, or supply `to` explicitly.
- Remote administration requires an explicit unicast destination: an integer or `!` followed by exactly eight hexadecimal digits. Broadcast, zero, malformed strings, and missing destinations are rejected. MQTT always requires `to`.
- Getter requests default `want_response: true`; state-changing operations default false. Explicit `want_response` overrides this. `want_ack` requests a separate routing acknowledgment. Some firmware setters answer with `ROUTING_APP` rather than an admin response when a response is requested.
- Common transport options include `channel`, `hop_limit`, `want_ack`, `last_packet_id`, and MQTT `psks`. Device-owned remote PKI uses `pki_encrypted` and `public_key` on radio transports; MQTT channel encryption is not PKI admin authorization.
- `get_channel(index: 0)` takes a **zero-based** index 0–7 and adds one exactly once for the wire. Raw `get_channel_request` passed to `encode`/`send` is already a wire value. `set_channel` retains the Channel protobuf's zero-based index.

## Encoding and validation

`encode` returns an `AdminMessage`, copying rather than modifying `message:` when provided. Supply exactly one payload variant. Conflicting variants, unknown option names, missing payloads, and nil payload values are rejected rather than silently overwriting the protobuf oneof. Protobuf field types and numeric bounds are enforced by the generated Ruby classes. False and zero are preserved, including `nodedb_reset: false`, `get_config_request: :DEVICE_CONFIG`, and backup location `:FLASH`.

Every generated payload field is available through `encode` and `send`, including response fields for tooling. Wrappers below accept the common transport options as well. Missing required scalar values are not silently converted to zero or empty text. An explicit empty ringtone or canned-message string may clear it.

## Operation catalog

| Group | Methods and payload arguments |
| --- | --- |
| Identity | `get_owner`; `set_owner(owner:)` or `set_owner(long_name:, short_name:)`; `set_ham_mode(ham:)` or callsign/frequency/power/name fields |
| Channels | `get_channel(index: 0)`; `set_channel(channel_settings:)` (or `channel_pb:`) |
| Configuration | `get_config(config_type: :DEVICE_CONFIG)`; `set_config(config:)`; `get_module_config(module_config_type: :MQTT_CONFIG)`; `set_module_config(module_config:)` |
| UI | `get_ui_config`; `store_ui_config(ui_config:)`; `send_input_event(event:)` or `event_code`, `kb_char`, `touch_x`, `touch_y` |
| Canned messages | `get_canned_messages`; `set_canned_messages(messages:)` with pipe-separated text |
| Ringtone | `get_ringtone`; `set_ringtone(ringtone:)` with RTTTL text |
| Device information | `get_device_metadata`; `get_device_connection_status`; `get_node_remote_hardware_pins` |
| Position/time | `set_fixed_position(position:)` or `lat`, `lon`, `altitude`; `remove_fixed_position`; `set_time(time:)` with Unix seconds |
| Node database | `remove_by_nodenum(node_num:)`; `set_favorite_node(node_num:)`; `remove_favorite_node(node_num:)`; `set_ignored_node(node_num:)`; `remove_ignored_node(node_num:)`; `toggle_muted_node(node_num:)`; `add_contact(contact:)` |
| Edit transactions | `begin_edit`; `commit_edit` — defer implicit persistence/reboot for owner/channel/config/module changes until commit |
| Preferences | `backup_preferences(location: :FLASH)`; `restore_preferences(location: :FLASH)`; `remove_backup_preferences(location: :FLASH)`; location may also be `:SD` |
| Files and sensors | `delete_file(path:)`; `set_scale(scale:)`; `sensor_config(sensor_config:)` |
| Authentication | `key_verification(key_verification:)`; `lockdown_auth(lockdown_auth:)` — typed protobuf payloads, not an automatic authentication workflow |
| Power | `reboot(seconds: 5)`; `shutdown(seconds: 5)`; negative delays cancel pending actions |
| Firmware | `enter_dfu`; `ota_request(event:)` with `AdminMessage::OTAEvent`; `reboot_ota(seconds: 5)` for deprecated legacy firmware only |
| Resets | `factory_reset_device(value: 1)`; `factory_reset_config(value: 1)`; `nodedb_reset(preserve_favorites: true)`; `exit_simulator` |
| Utilities | `encode`; `send`; `request`; `decode`; `response`; `help`; `authors` |

Device reset clears BLE bonds; config reset preserves them. `nodedb_reset(preserve_favorites: false)` requests removal of favorites too, but firmware CLIENT_BASE/ROUTER/ROUTER_LATE roles can preserve favorites regardless. DFU is hardware-specific (upstream documents NRF52); OTA depends on the installed loader and supported mode. Modern firmware uses `ota_request`; `reboot_ota_seconds` is deprecated and absent from the inspected current AdminModule switch. Use [Admin::Firmware](admin-firmware.md) for the firmware transfer workflow.

## Responses, correlation and session passkeys

`decode(payload: bytes)` decodes raw AdminMessage bytes. `decode(packet:)` accepts a protobuf `FromRadio`, `MeshPacket`, or `Data` and requires decoded `ADMIN_APP` data. Malformed protobuf bytes raise the protobuf decoder error.

`response(packet:, request_id:, from:)` accepts a `FromRadio` or `MeshPacket`, optionally matches the outgoing packet ID and numeric sender, and returns:

```ruby
{ message: admin_message, variant: :get_owner_response, value: owner,
  session_passkey: passkey_bytes, request_id: packet_id, from: node_number }
```

Unrelated ports, non-response variants, encrypted/absent data, and mismatched IDs/senders return nil. These helpers do not authenticate packets or decrypt encrypted packets. `response` remains a pure decoder; use `request` for synchronous routing-error handling.

### Synchronous request/readback

`request` accepts raw `send` options or `message: AdminMessage`, plus `timeout:` (positive finite seconds, default 10), `request_id:` and `wait:`. By default it sends and waits on the connected radio's `from_radio_queue`. A getter returns the response hash above plus `result:` (the transport submission result). It requires both the outgoing request ID and target node, and the expected response variant. A local routing ACK is **not** remote readback. State-changing requests wait for a target-correlated `ROUTING_APP/NONE` and return `{ variant: :routing, value: :NONE, request_id:, from:, result: }`; even this is acknowledgment, not verification of persistent configuration.

```ruby
reply = Meshtastic::Admin.request(
  serial_obj: serial_obj, # alternatively bluetooth_obj: or tcp_obj:
  to: '!aabbccdd',
  message: Meshtastic::AdminMessage.new(get_device_metadata_request: true),
  timeout: 10
)
version = reply[:value].firmware_version
```

After reboot, reconnect, complete the transport handshake, and make this request on the **new handle**. Match the returned version against the expected firmware; neither a successful upload nor an ACK establishes firmware health.

- `Timeout::Error` means no matching response arrived within the monotonic receive budget, or the receive queue closed. The budget includes automatic session acquisition. Blocking transport writes retain their underlying transport's I/O behavior; this is not an interrupting write timeout.
- `Admin::RoutingError` exposes `reason`, `request_id`, and `from`. Correlated nonzero routing errors from the target **or connected local radio** terminate immediately (including local PKI/no-route failures).
- Unrelated packets are retained and returned to the queue on success or failure. Deferred packets can move behind newer queued traffic. If the queue closes, the handle receives a replacement closed queue retaining those packets. Do not retain a separate queue reference across disconnects.
- Pause any external `subscribe`/`recv_from_radio` consumer while a synchronous request owns the receive queue. Concurrent synchronous requests on one handle fail fast with `IOError`; Admin does not install a global transport dispatcher.
- MQTT has no compatible radio queue; synchronous requests and automatic acquisition are rejected rather than pretending submission is readback.
- `request(wait: false, ...)` retains the old `{ request_id:, result: }` submission-only API, including MQTT. Use your existing receive loop with `response` in that mode. Automatic remote session acquisition can still wait unless an explicit key or `auto_session: false` is supplied.
- IDs are generated or supplied with `request_id:` (2 through `0xffffffff`), overriding `last_packet_id`. Use fresh IDs; deliberately reusing one cannot distinguish a stale reply. ID 1 is excluded because transport predecessor zero requests a random ID.

### Automatic sessions

Remote state-changing `send` calls (including convenience setters, reboot, and firmware commands) automatically request `get_config_request: :SESSIONKEY_CONFIG` before transmitting when no passkey was supplied. Acquisition must return a correlated `get_config_response` containing exactly eight passkey bytes; otherwise the write is not sent. Reads and local PhoneAPI operations do not need acquisition. An explicit eight-byte `session_passkey:` or a passkey already in `message:` bypasses acquisition; `auto_session: false` explicitly disables it. For MQTT provide the key obtained through your own authorized receive workflow.

The key is cached **only in the connection handle, scoped by target node**. A matching synchronous getter refreshes that target's cache. Cache entries expire conservatively after 150 seconds measured from the start of acquisition; `refresh_session: true` forces a new acquisition. `ADMIN_BAD_SESSION_KEY` invalidates the target cache, so the **next caller-initiated** write acquires again. No state-changing request is automatically replayed, including on timeout or rejection. Reconnect with a new handle after reboot to discard old state.

The node's passkey is not its public/private key, channel PSK, or a substitute for remote admin authorization. Upstream exempts local PhoneAPI commands (`from == 0`) and enumerated getters/responses from passkey checks. Other remote commands require it. Firmware expires keys after 300 seconds and can rotate them when issuing a response after 150 seconds; another controller can therefore invalidate even a locally unexpired key. The library does not log keys or payloads; response hashes and connection handles contain secrets, so do not log or serialize them. `:SESSIONKEY_CONFIG` carries the key in the **AdminMessage envelope**, not the Config payload.

Convenience getters and `send` still return the transport submission result. They do not wait for readback; use `request` when verification matters.

## Sources and compatibility

Official upstream sources inspected for the wire contract and firmware behavior:

- [admin.proto](https://github.com/meshtastic/protobufs/blob/master/meshtastic/admin.proto)
- [AdminModule.cpp](https://github.com/meshtastic/firmware/blob/master/src/modules/AdminModule.cpp)

The generated protobuf schema can expose fields not implemented by an installed firmware build. Sensor, key-verification, lockdown, module-specific handlers, simulator, SD, DFU, and OTA functionality remain firmware/hardware dependent. Encoding a field does not establish that a device supports it. This implementation was verified with real Ruby protobuf encoding and fake transports, not live hardware.

## Related

- [Admin::Channel](admin-channel.md)
- [Admin::Config](admin-config.md)
- [Admin::Firmware](admin-firmware.md)
- [Channel](channel.md)
- [Config](config.md)
- [ModuleConfig](module-config.md)
- [RTTTL](rtttl.md)
