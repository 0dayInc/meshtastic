# Meshtastic::MeshInterface

Packet builder used by Serial, Bluetooth, TCP, and MQTT. Instantiated internally; you can also call it directly to get protobuf bytes without writing a radio.

## Instance methods

- `initialize(debug_out:, is_connected:, is_proto:, no_nodes:)`
- `generate_packet_id(last_packet_id:)`
- `get_cipher_keys(psks:)` — normalize Base64 PSK hash keys
- `gps_search(lat:, lon:)` — Geocoder reverse lookup
- `start_config` — `ToRadio.want_config_id` bytes
- `my_node_info`
- `send_packet` — encrypt when `psks` present; `via: :radio` → `ToRadio`, `via: :mqtt` → `ServiceEnvelope`
- `send_data` / `send_text`
- `send_to_radio` / `send_to_mqtt` — serialize only
- `decode_payload` — TEXT_MESSAGE_APP as UTF-8; other portnums as nested protobufs when known
- `help` / `authors`

On Serial/Bluetooth/TCP, transports pass `psks: nil` so the radio owns channel crypto. MQTT must pass `psks`.

`send_data` and `send_packet` preserve `pki_encrypted: true` and `public_key:`
(32 raw bytes) for remote administrative requests. The connected radio performs
the public-key encryption; the Ruby client does not encrypt these packets itself.
Explicit PKI requests reject MQTT and host-side PSK encryption instead of silently
falling back to channel encryption. Supplying a recipient key does not grant admin
rights: the target must authorize the sending radio's key.

`send_text` refuses payloads larger than `Meshtastic::Constants::DATA_PAYLOAD_LEN`.

## Example

```ruby
mesh = Meshtastic::MeshInterface.new
bytes = mesh.start_config

text_bytes = mesh.send_text(
  from: '!11223344',
  to: '!ffffffff',
  channel: 0,
  text: 'Hello',
  via: :radio,
  psks: nil
)

envelope = mesh.send_text(
  from: '!c0ffee00',
  to: '!ffffffff',
  channel: 93,
  text: 'Hello MQTT',
  via: :mqtt,
  psks: { LongFast: 'AQ==' }
)
```

## Related

- [Meshtastic::Serial](serial.md)
- [Meshtastic::MQTT](mqtt.md)
- [Meshtastic::Portnums](portnums.md)
