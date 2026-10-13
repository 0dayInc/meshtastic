# Meshtastic::MQTT

Broker client using protobuf `ServiceEnvelope`. The host performs channel PSK encryption/decryption; MQTT does **not** provide public-key direct messaging. A broker publish is submission, not RF delivery or a verified ACK.

## Connect and subscribe

```ruby
require 'meshtastic'

mqtt_obj = Meshtastic::MQTT.connect(
  host: 'mqtt.meshtastic.org', port: 1883, tls: false,
  username: 'meshdev', password: 'large4cats',
  client_id: 'aabbccdd', keep_alive: 15, ack_timeout: 30
)

# Use your own Base64 16- or 32-byte channel key, not this public alias.
keys = {
  LongFast: 'AQ==',                         # backward-compatible AES-CTR
  Private: { psk: 'AQ==', use_aead: true }  # firmware AES-CCM, public example key
}

Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj, root_topic: 'msh', region: 'US',
  topic: '2/e/Private/#', psks: keys, qos: 0,
  include: nil, exclude: nil, gps_metadata: false, include_raw: false
) do |envelope|
  puts envelope[:packet].inspect
end
```

`subscribe` is blocking and disconnects on exit. `include`/`exclude` are comma-delimited substrings. `json: true` accepts JSON envelopes but does not make their security claims trustworthy. Binary protobuf is the normal interoperable path.

The exact `ServiceEnvelope.channel_id` selects the key. If absent, the penultimate MQTT topic segment is used. Unknown names never fall back to LongFast or the first key. Encrypted packets must have the firmware hash matching the configured name, expanded key and mode. Already-decoded envelopes bypass host decryption and are not authenticated by it.

## Send text or application Data

```ruby
Meshtastic::MQTT.send_text(
  mqtt_obj: mqtt_obj, from: '!aabbccdd', to: '!ffffffff',
  channel_id: 'Private', psks: keys,
  text: 'Hello', want_ack: false, hop_limit: 3
)

Meshtastic::MQTT.send_data(
  mqtt_obj: mqtt_obj, from: '!aabbccdd',
  channel_id: 'Private', psks: keys,
  data: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP, payload: 'Hello')
)
```

- `channel_id:` selects the exact channel name. It may be omitted only for a single configured key; omitted `psks` retains the public LongFast CTR default. Multiple keys without a selector, duplicate string/symbol names, unknown selectors, and conflicting publication topics raise `ArgumentError` before publish.
- `psks:` maps names to Base64 strings (legacy CTR), or `{ psk: base64_string, use_aead: true/false }`. `use_aead` belongs **inside each key record**, not at the top level. Structured records require exactly `psk` and a boolean `use_aead`; omitted/misspelled modes and top-level `use_aead` are rejected rather than silently selecting CTR. No mode probing or AEAD-to-CTR retry occurs.
- Keys must decode to 16 or 32 bytes, or a nonzero one-byte firmware PSK alias. Aliases 1–255 expand using the firmware default key and last-byte adjustment on **any** channel name. Empty/zero aliases, malformed keys and other lengths are rejected; unlike firmware, arbitrary short keys are not silently zero-padded. Resolve secondary-channel inherited keys before supplying them here. Public aliases do not provide confidentiality.
- The packet channel hash is computed, not guessed: XOR all UTF-8 channel-name bytes and expanded key bytes, then XOR `0xAE` for AEAD. Legacy numeric `channel:` remains accepted but does not override this computed MQTT hash. On radio transports, `channel:` is still a device slot.
- The default publish path is `msh/US/2/e/<selected channel>/<from>`. Supply `root_topic`, `region`, or `topic: '2/e/Private/#'` to customize. A topic must identify the selected channel.
- `send_text` and text `send_data` reject nonbroadcast destinations, even without `pki_encrypted`. Explicit `pki_encrypted: true` or recipient `public_key:` also raise. Use Serial/Bluetooth/TCP with device-owned PKI for direct messages. Non-text channel-addressed application Data remains supported, but is not PKI.
- `psks: nil` and `{}` cannot publish plaintext. `send_text` enforces the payload byte limit. Large encoded Data plus AEAD overhead still must fit the receiving firmware's RF limits; publish success does not prove airtime acceptance.
- Do not reuse a packet ID with the same sender/key. Normal sends generate IDs; `last_packet_id:` exists for controlled sequencing/testing, not replay protection. The host does not maintain a durable nonce/replay database.

`disconnect(mqtt_obj:)`, `help`, and `authors` are also available.

## Security provenance

Every enriched packet has host-created `:security_provenance`:

```ruby
{
  source: :mqtt,
  verification: :untrusted,
  reported: { xeddsa_signed: true, ack_proof_status: :ACK_PROOF_VALID },
  channel_authentication: :aead # only after a successful local CCM check
}
```

Broker `xeddsa_signed` and `ack_proof_status` are removed from the top-level packet hash and retained only under `reported`. They are untrusted broker assertions, including on already-decoded packets, encrypted packets and failed-enrichment paths. A broker-supplied `security_provenance` is overwritten. `include_raw` is wire evidence, not a trusted verification result.

Successful CCM proves possession of the shared channel key, **not** sender identity, XEdDSA signature validity, ACK proof validity, freshness or radio delivery. CTR decoding sets `channel_authentication: :none`; protobuf parsing is not authentication. Failures preserve ciphertext and add `decryption_error` without publishing partial plaintext. PKI ciphertext is never attempted with PSK crypto.

## Pinned firmware interoperability

Implemented against release **v2.8.1.8e6a88d**:

- Firmware [`8e6a88d06f44cad26f1e8d7cd402939ccacb9b4c`](https://github.com/meshtastic/firmware/tree/8e6a88d06f44cad26f1e8d7cd402939ccacb9b4c): `src/mesh/Channels.cpp`, `CryptoEngine.cpp/.h`, `aes-ccm.cpp`, and `test/test_crypto/test_main.cpp`.
- Protobuf [`8f97d66a63ce10cfb12f94203e361691647f5ad3`](https://github.com/meshtastic/protobufs/tree/8f97d66a63ce10cfb12f94203e361691647f5ad3): existing `ChannelSettings.use_aead`, `MeshPacket.xeddsa_signed` and `ack_proof_status` schemas.

CTR uses AES-128/256 with the 16-byte nonce `packet_id64le || from32le || zero32`. Channel AEAD uses AES-128/256-CCM, **13-byte nonce** `packet_id64le || from32le || 00`, **12-byte tag**, and AAD `from32le || to32le`. Wire bytes are `ciphertext || tag`; there is no PKI extra nonce. Relayed hop fields are not AAD. Packet IDs in MeshPacket are 32-bit and occupy the low four bytes of the 64-bit nonce field.

Ruby OpenSSL must provide AES-CCM, `iv_len=`, `auth_tag_len=`, `ccm_data_len=`, and authenticated decrypt. Unsupported crypto fails, never downgrades. No new gem/native extension dependency was added. Tests use fixed independently calculated CCM vectors, upstream RFC3610 validation, real ServiceEnvelope/FromRadio codecs, fake broker/GATT, PTY UART and UNIXSocket TCP; no hardware or live broker was used.

## Related

- [MeshInterface](mesh-interface.md)
- [Protobuf catalog](protobufs.md)
