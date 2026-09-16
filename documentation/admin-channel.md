# Meshtastic::Admin::Channel

Build, read, write, and share mesh channels using `ADMIN_APP`. The generated protobuf remains `Meshtastic::Channel`. All public methods accept one options Hash.

## Channel operations

- `build_settings(settings:, ...)` copies an optional `ChannelSettings` protobuf or field Hash and overlays explicit settings without mutating the input. Supports **every bundled field**: `channel_num`, raw-byte `psk`, `name`, `id`, `uplink_enabled`, `downlink_enabled`, `module_settings`, `use_aead`. Nested `module_settings` accepts a `Meshtastic::ModuleSettings` or Hash, including `position_precision` and `is_muted`. Explicit `false` clears booleans.
- `build(channel:, index:, role:, settings:, ...)` copies an optional Channel protobuf, preserving its settings and overlaying supplied values. Defaults to slot zero and protobuf role `:DISABLED`; choose `:PRIMARY` or `:SECONDARY` explicitly when enabling a channel.
- `get(index:)` requests a **zero-based** slot (default 0). `Admin.get_channel` converts to the protocol's **one-based request**: slot 0 sends `get_channel_request = 1`. Response and set-channel indexes remain zero-based. Never add one yourself.
- `set(channel:, index:, role:, settings:, ...)` builds/validates a Channel and sends it through Admin. A supplied Channel can be overlaid with explicit settings. Slots must be Integers from 0 through 7; numeric strings and fractional indexes are rejected. Unsupported roles, invalid PSK lengths, and overlong names are rejected before sending.
- `help` / `authors` show usage and attribution.

Channel names must occupy fewer than 12 UTF-8 bytes. PSKs accept 0, 1, 16, or 32 raw bytes; they are **not** hex/base64 strings. Empty keys disable encryption; one-byte keys are public shorthand keys, not secure random keys. `channel_num` is deprecated in ChannelSettings: configure frequency selection with `Admin::Config.set_lora` instead. AEAD is experimental and peers must agree on its use.

```ruby
settings = Meshtastic::Admin::Channel.build_settings(
  name: 'Example', psk: "\x01".b,
  uplink_enabled: false,
  module_settings: { position_precision: 13, is_muted: false }
)
Meshtastic::Admin::Channel.set(
  transport_obj: connection, index: 1, role: :SECONDARY, settings: settings
)
Meshtastic::Admin::Channel.get(transport_obj: connection, index: 1)

# Explicitly disable a slot.
Meshtastic::Admin::Channel.set(transport_obj: connection, index: 1, role: :DISABLED)
```

Admin transport/routing/authentication options pass through (`transport_obj: connection`, `to`, `from`, `session_passkey`, etc.). Here `channel:` means a **Channel protobuf**, not the outgoing mesh transport channel selector; it is removed before delivery. Use the lower-level `Admin.set_channel(channel_settings: protobuf, channel: numeric_index, ...)` when a particular transport channel is necessary.

## Channel URLs

Official clients share a protobuf `Meshtastic::ChannelSet` using unpadded URL-safe Base64 in the fragment of `https://meshtastic.org/e/#...` (legacy `/d/#...` imports are also accepted).

- `export_url(channels:, lora_config:, include_all:)` is offline. Requires exactly one primary, puts it first, sorts secondary channels by slot, and omits disabled slots. `include_all: false` exports only the primary; default includes secondaries. An optional LoRaConfig protobuf/Hash is included without fetching hardware. Up to eight enabled channels are accepted.
- `import_url(url:)` is offline and returns the decoded ChannelSet, preserving settings and optional LoRaConfig. Accepts padded or unpadded Base64 from HTTPS `meshtastic.org` e/d URLs only, with no userinfo or alternate port. Malformed protobuf/Base64, missing fragments, and zero or more than eight settings are rejected with a generic error that does not echo the secret URL. It does not assign device slots or modify a radio.
- `apply_url(url:, transport_options...)` explicitly writes imported settings into consecutive slots starting at zero: first PRIMARY, remaining SECONDARY. All channel settings are validated before the first write. Optional LoRa config is written last; absent LoRa config is left unchanged. Returns the individual transport submission results. **Existing higher slots are left untouched**, matching the official Python client's replacement behavior. Add-only/query links are rejected before transmission; for adding channels, import offline, inspect existing slots, and call `set` with explicitly chosen secondary slots.

```ruby
# channels and lora_config are protobufs already obtained from the node.
url = Meshtastic::Admin::Channel.export_url(
  channels: channels, lora_config: lora_config
)
channel_set = Meshtastic::Admin::Channel.import_url(url: url)

# Only when replacement of slots from zero is intended:
Meshtastic::Admin::Channel.apply_url(transport_obj: connection, url: url)
```

**URLs contain channel keys.** Treat them as credentials: do not log, publish, or send them to third-party QR services. Export does not redact PSKs. A URL carries settings, not original slot indexes/roles: its first entry becomes primary when applied.

## Operational limits

Writes are submissions, not delivery/persistence acknowledgements. No live hardware was exercised. Admin's automatic remote session-key acquisition applies. No automatic write-acknowledgment collection, readback, edit transaction, rollback, or add-only merge is performed. URL application can partially succeed if transport or firmware fails mid-sequence, and changing LoRa/primary settings can disconnect remote administration. For radio use, manage edit transactions and ACK/readback through Admin as appropriate for the firmware; verify slots and LoRa configuration after writing.

## Protocol evidence

- [Official Admin schema](https://github.com/meshtastic/protobufs/blob/master/meshtastic/admin.proto): `get_channel_request` is index + 1.
- [Official Channel schema](https://github.com/meshtastic/protobufs/blob/master/meshtastic/channel.proto): roles, settings, PSK/name constraints, deprecated channel_num.
- [Official app-only schema](https://github.com/meshtastic/protobufs/blob/master/meshtastic/apponly.proto): ChannelSet contains primary-first settings, secondaries, and optional LoRa config.
- [Official Python node client](https://github.com/meshtastic/python/blob/master/meshtastic/node.py): `_requestChannel`, `getURL`, and `setURL` establish index and sharing/application semantics. Python is reference evidence only; this implementation is Ruby.

Related: [Admin](admin.md), [Config](admin-config.md).
