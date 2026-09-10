# Meshtastic::MQTT

Broker client. The host encrypts and decrypts with channel PSKs. Default public broker is `mqtt.meshtastic.org` (port 1883, user `meshdev`).

`channel:` on MQTT is the integer hash seen in envelopes, not the radio channel index (that is Serial/Bluetooth/TCP).

## Methods

- `connect` — returns an `MQTT::Client`
- `subscribe` — blocking loop; yields a hash per envelope, or pretty-prints without a block. Disconnects on exit.
- `send_text` — publishes a `ServiceEnvelope` (raises if text exceeds `Meshtastic::Constants::DATA_PAYLOAD_LEN`)
- `disconnect`
- `help` / `authors`

### `connect`

```ruby
mqtt_obj = Meshtastic::MQTT.connect(
  host: 'mqtt.meshtastic.org',
  port: 1883,
  tls: false,
  username: 'meshdev',
  password: 'large4cats',
  client_id: nil,          # default: random 4-byte hex
  keep_alive: 15,
  ack_timeout: 30
)
```

### `subscribe`

```ruby
Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj,
  root_topic: 'msh',
  region: 'US',
  topic: '2/e/LongFast/#',
  psks: { LongFast: 'AQ==' },
  qos: 0,
  exclude: nil,            # comma-delimited substrings to hide
  include: nil,            # all listed substrings must appear
  gps_metadata: false,
  include_raw: false
) do |message|
  puts message.inspect
end
```

`include: '_APP, LongFast'` keeps only messages whose flattened inspect contains both strings.

### `send_text`

```ruby
require 'meshtastic'

mqtt_obj = Meshtastic::MQTT.connect
client_id = "!#{mqtt_obj.client_id}"
Meshtastic::MQTT.send_text(
  mqtt_obj: mqtt_obj,
  from: client_id,
  to: '!ffffffff',
  root_topic: 'msh',
  region: 'US',
  topic: '2/e/LongFast/#',
  channel: 93,
  text: 'Hello, World!',
  psks: { LongFast: 'AQ==' }
)
```

Default `channel` is `6`. The value that actually works is the integer in a received envelope for that mesh channel. Subscribe with `include: '!YOUR_CLIENT_ID'` while sending a test message from the official app:

```ruby
mqtt_obj = Meshtastic::MQTT.connect
Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj,
  root_topic: 'msh',
  region: 'US',
  topic: '2/e/LongFast/#',
  psks: { LongFast: 'AQ==' },
  include: '!c0ffee00'
) do |message|
  puts message.inspect
end
```

Example envelope (placeholders):

```
{packet: {from: 3237997296, to: 4294967295, channel: 93, id: 1, rx_time: 1735689600, rx_snr: 0.0, hop_limit: 3, want_ack: false, priority: :HIGH, rx_rssi: 0, delayed: :NO_DELAY, via_mqtt: false, hop_start: 3, public_key: "", pki_encrypted: false, next_hop: 0, relay_node: 0, tx_after: 0, decoded: {portnum: :TEXT_MESSAGE_APP, payload: "WHAT IS MY channel VALUE?", want_response: false, dest: 0, source: 0, request_id: 0, reply_id: 0, emoji: 0, bitfield: 0}, encrypted: :decrypted, topic: "msh/US/2/e/LongFast/!c0ffee00", node_id_from: "!c0ffee00", node_id_to: "!ffffffff", rx_time_utc: "2025-01-01 00:00:00 UTC"}, channel_id: "LongFast", gateway_id: "!c0ffee00"}
```

Use `channel: 93` from that dump when publishing.

`AQ==` is expanded to the well-known LongFast PSK. Pass a Base64 channel key for private channels.

## Related

- [Meshtastic::MeshInterface](mesh-interface.md) (`via: :mqtt`)
- [Meshtastic::Portnums](portnums.md)
- Protobuf: `ServiceEnvelope`, `MapReport` in [protobufs.md](protobufs.md)
