# Admin::Backup — native host-side configuration snapshots

`Meshtastic::Admin::Backup` exports a versioned JSON document (default) or binary
Meshtastic `DeviceProfile` (`format: :device_profile`) using fresh,
request-ID/source-correlated Admin requests. It imports validated protobuf
sections with bounded routing ACK waits. It does not invoke the firmware's
filesystem backup/restore commands or shell out to another client.

**Backups contain secrets by default**, including channel PSKs, Wi-Fi/MQTT
credentials, private security keys and UI PINs when firmware returns them in
selected sections. Keep the file and returned Hash private; do not print either
in logs. Firmware can redact secrets or return default/empty values. Such a
snapshot cannot recover values the device did not disclose. Importing those
values can clear existing settings. Review the selection before exporting and
before restoring, especially across devices or firmware versions.

## Export

```ruby
require 'meshtastic'
require 'meshtastic/admin/backup'

snapshot = Meshtastic::Admin::Backup.export(
  transport_obj: connection,
  path: '/private/directory/node-backup.json', # optional; MUST NOT exist
  config_types: %i[DEVICE_CONFIG POSITION_CONFIG POWER_CONFIG DISPLAY_CONFIG LORA_CONFIG],
  module_config_types: %i[MQTT_CONFIG TELEMETRY_CONFIG],
  channel_indexes: [0, 1],
  include_owner: true,
  include_ui: false,
  timeout: 10
)
# Safe to display status/count; NOT snapshot[:backup].
snapshot.slice(:status, :count)
```

`transport_obj:` is a connected Serial, Bluetooth or TCP handle with a receive
queue. **MQTT synchronous export/import is explicitly unsupported**, including
dry runs. `to:` optionally selects a unicast target; otherwise the connected
local node is used. `channel:` and `hop_limit:` are Admin delivery options.
Pause external queue consumers and do not interleave other Admin edits with a
backup/restore. The underlying Admin layer serializes individual requests,
not an entire multi-request snapshot or transaction.

JSON selection defaults (binary-specific differences are listed below):

- `include_owner: true`: only `long_name`, `short_name`, `is_licensed`.
  Never clone User ID, MAC, hardware model, public key, role or messaging
  capability metadata. Role belongs to device configuration; security keys
  belong to explicitly selected security configuration.
- `config_types:` defaults to `DEVICE_CONFIG`, `POSITION_CONFIG`, `POWER_CONFIG`,
  `NETWORK_CONFIG`, `DISPLAY_CONFIG`, `LORA_CONFIG`, `BLUETOOTH_CONFIG`,
  `SECURITY_CONFIG`. Use a narrower list for firmware that lacks sections.
- `module_config_types: []`: opt in to supported module ConfigType symbols.
  All 17 currently generated ModuleConfig sections are supported, including
  `EXTNOTIF_CONFIG`, `STOREFORWARD_CONFIG`, `CANNEDMSG_CONFIG`,
  `STATUSMESSAGE_CONFIG`, `TRAFFICMANAGEMENT_CONFIG`, `TAK_CONFIG`,
  `MESHBEACON_CONFIG`. `Backup::MODULE_TYPES` lists the complete set.
- `channel_indexes: [0, 1, 2, 3, 4, 5, 6, 7]`: explicit zero-based slots,
  including disabled channels. Wire getters use one-based indexes.
- `include_ui: false`: opt in to dedicated get/store UI operations.
- `timeout: 10`: positive finite seconds **per Admin request**, not a deadline
  for the entire backup. Remote writes can first acquire an Admin session.

Unsupported selected sections fail the export; they are not silently skipped.
No file is created until every selected response has been collected and the
document validated. Empty JSON selections are allowed. A successful JSON return contains
`:status => :exported`, `:count`, `:backup` and `:warnings`. A read error raises.
Snapshots are sequential fresh reads, not an atomic device-wide snapshot.

Files are exclusively created with mode `0600`, `O_EXCL` and `O_NOFOLLOW`, then
flushed and fsynced. There is no overwrite flag. Existing files and final-path
symlinks fail. Use a trusted parent directory: parent-directory symlinks are not
resolved or pinned. A disk write/sync failure raises and can leave a partial
0600 file; it is never reported as a successful backup. File mode protection is
not encryption and does not protect against privileged host access.

## Validate, plan and import

```ruby
plan = Meshtastic::Admin::Backup.import(
  transport_obj: connection,
  path: '/private/directory/node-backup.json',
  dry_run: true
)

result = Meshtastic::Admin::Backup.import(
  transport_obj: connection,
  backup: snapshot[:backup], # use exactly one of backup: or path:
  edit_transaction: true,   # ONLY when target firmware supports it
  verify: true,
  timeout: 10
)
```

`dry_run: true` performs **no radio requests or writes**, including no session
acquisition, edit begin, getters or readback. It validates the entire document
first. `dry_run`, `edit_transaction` and `verify` default to `false` and must be
booleans. Unknown options are rejected. Import paths must be regular files and
must not be final-path symlinks.

The importer rejects incompatible format/version, unknown document/record/
protobuf fields, unknown section selectors, duplicate section/slot records,
invalid channel indexes, section/slot mismatches, conflicting oneofs, malformed
protobuf scalar values, null values and noncanonical bytes/base64 **before any
radio request**. A version-1 document is a Hash with string keys:

```json
{
  "format": "meshtastic-admin-backup",
  "version": 1,
  "warning": "A human-readable limitations notice",
  "records": [
    {
      "section": "config",
      "slot": "DEVICE_CONFIG",
      "value": { "device": { "serial_enabled": false } }
    }
  ]
}
```

Sections are `owner`, `config`, `module_config`, `channel`, `ui`. Owner/UI slots
are JSON null; config/module slots are uppercase enum names; channel slots are
integers. `value` is protobuf JSON with **snake_case protobuf field names**,
canonical base64 bytes, protobuf enum representations and emitted scalar
defaults. Known fields and protobuf presence/default semantics round-trip;
unknown binary wire fields are not archived. This is not an opaque protobuf
wire backup. Missing fields in a manually edited document mean protobuf
defaults, not a patch/merge. YAML and arbitrary object deserialization are never
used. Session envelope passkeys and `SESSIONKEY_CONFIG` are never exported or
accepted; automatic session state stays inside the existing Admin connection.

Writes preserve input order within priority groups: ordinary owner/module/UI/
core settings first, channels next, then LoRa, Bluetooth, network and security.
These latter settings can disrupt the connection. Other firmware-specific
settings can also disrupt it; ordering cannot guarantee connectivity.

## Binary DeviceProfile (`.cfg`) export and import

Select binary output explicitly; export accepts only `format: :json` (default)
or `format: :device_profile`, not `:auto`. The path extension does not choose
export format. JSON version-1 output and return keys are unchanged.

```ruby
snapshot = Meshtastic::Admin::Backup.export(
  transport_obj: connection,
  format: :device_profile,
  path: '/private/directory/nodeConfig.cfg', # optional; MUST NOT exist
  config_types: %i[DEVICE_CONFIG POSITION_CONFIG LORA_CONFIG],
  module_config_types: %i[MQTT_CONFIG TELEMETRY_CONFIG],
  channel_indexes: [0, 1], # actual contiguous PRIMARY/SECONDARY slots only
  include_owner: true,
  include_ui: false,
  include_ringtone: true,
  include_canned_messages: true,
  timeout: 10
)
# Safe status fields only. NEVER print backup bytes or decoded profile.
snapshot.slice(:status, :format, :count)
# snapshot[:backup] is a raw ASCII-8BIT String, not JSON/base64 or a protobuf object.
# Pass it directly to Backup.import(transport_obj: connection,
#                                 backup: snapshot[:backup], dry_run: true).
```

Binary returns `{ status: :exported, format: :device_profile, count: Integer,
backup: binary_string, warnings: [...] }`. `count` is the number of restorable
sections (owner counts once, each channel counts once, duplicate URL/config
LoRa counts once), not the byte count or number of protobuf fields. The `.cfg`
file contains exactly `snapshot[:backup]`. File protections are the same
exclusive/no-follow 0600 creation, flush and fsync as JSON. No file is created
until reads and strict binary validation succeed.

Binary selection uses the same core/module/owner/channel defaults as JSON,
with these format-specific rules:

- All eight core and 17 module selections are supported. Present empty nested
  messages, byte fields, repeated values and scalar defaults round-trip. Local
  container storage versions are not invented.
- Owner names and license flag are explicitly present, including empty names
  and `false`. Optional `is_unmessagable` is copied only when present in the
  fresh User response, including explicitly present `false`. ID, MAC, hardware,
  public key and envelope session passkeys are not copied.
- `include_ui: true` is **rejected before any radio requests**: DeviceProfile
  has no UI field. Use JSON for UI snapshots.
- ChannelSet URLs cannot preserve arbitrary indexes or disabled slots. Select
  `channel_indexes: []` to omit channels, or an ordered contiguous prefix such
  as `[0]` or `[0, 1]`. Sparse/reordered selections are rejected before requests.
  Returned slot 0 must be PRIMARY, later selected slots SECONDARY, each with
  settings; mismatched indexes, disabled slots and other roles fail export
  without creating a file. No selected channel is silently skipped or moved.
  **The default all-eight selection therefore fails if any slot is disabled**;
  choose the actual enabled prefix or use JSON to preserve disabled/sparse slots.
  Selected LoRa is included identically in both `config.lora` and the URL;
  if LoRa is not selected, the URL does not invent or fetch it. Unselected
  trailing channel slots are not disabled by a later binary import.
- `include_ringtone: true` and `include_canned_messages: true` request fresh
  strings and preserve present empty strings. Both default to false and are
  binary-only options; JSON rejects these keys rather than ignoring them.
- `fixed_position:` optionally accepts an explicit `Meshtastic::Position` or
  field Hash, e.g. `{ latitude_i: 0, longitude_i: 0, altitude: 0 }`. It is
  validated before any requests and copied with protobuf presence/defaults.
  This is caller-supplied input, **not a fresh radio read**: no dedicated Admin
  getter exists. It defaults to absent and is binary-only. No position is
  inferred from cached GPS data or the position configuration.
- An entirely empty binary selection is rejected before requests because it
  would not produce an importable profile. JSON still permits empty records.

The importer accepts the same binary `meshtastic.DeviceProfile` used by
Meshtastic clients, entirely in Ruby.
Use exactly one source and select `format: :device_profile` explicitly, or use
`format: :auto` (the default for import):

```ruby
plan = Meshtastic::Admin::Backup.import(
  transport_obj: connection,
  path: '/private/directory/nodeConfig.cfg',
  format: :device_profile,
  dry_run: true
)
# Only section/slot identities and counts are returned; no profile contents.
plan.slice(:status, :planned, :plan)

# Alternative in-memory source, still offline validation with no radio requests:
plan = Meshtastic::Admin::Backup.import(
  transport_obj: connection,
  backup: binary_profile_string,
  format: :device_profile,
  dry_run: true
)
```

`format:` accepts only `:auto`, `:json`, or `:device_profile`. In auto mode a
`.cfg` path (case-insensitive) selects binary, `.json` selects JSON, and a Hash
selects the existing JSON document API. Other paths and Strings are validated
as binary first, then as JSON when JSON-looking content fails binary validation.
This avoids confusing a valid binary name field beginning with a newline and
`{` with JSON. Explicit format overrides the extension. JSON Strings are also
accepted; versioned JSON Hash behavior and JSON export selections are unchanged.
No YAML, executable serialization, or implicit protobuf object input is used.

Presence-aware mapping:

- Present `long_name`, `short_name`, `is_licensed`, and `is_unmessagable` become
  one `owner`/`set_owner` operation. Explicit `false` and empty names are not
  treated as absent. User identity/MAC/hardware/public-key fields are never
  synthesized. The Admin User schema has no presence for names/license, so
  omitted members of a sent owner message carry protobuf defaults; this is not
  a read/merge patch API. Firmware determines how those defaults are applied.
- Every present `LocalConfig` and `LocalModuleConfig` message becomes its own
  writable Config/ModuleConfig oneof, including present empty submessages.
  All eight core and 17 module sections are supported. Nested bytes, repeated
  values, defaults and optional presence are retained. The local containers'
  `version` fields are storage-schema metadata, not Admin settings; they are
  validated but not written. A metadata-only/empty profile is rejected.
- `channel_url` must be an HTTPS `meshtastic.org/e/` or `/d/` URL with a valid
  base64url ChannelSet and one through eight settings, no query or userinfo.
  Settings map in order to primary slot 0 and secondary slots 1–7; unlisted
  trailing slots are **not** disabled. PSK lengths and channel-name bounds are
  checked. Embedded LoRa configuration is restored too. If both the profile and
  URL carry LoRa, equal messages are deduplicated; conflicting messages reject
  the entire profile rather than silently choosing one.
- Present `fixed_position`, `ringtone`, and `canned_messages` map respectively
  to `set_fixed_position`, `set_ringtone_message`, and
  `set_canned_message_module_messages`, with nil slots and matching section
  names in the plan. Zero coordinates/altitude and present empty strings are
  preserved. Absent fields are not turned into clears or removal operations.

The **entire** binary profile and nested ChannelSet are validated before any
Admin request, including session acquisition or begin-edit. A strict recursive
wire check rejects unknown tags (including sessionkey additions), unknown enum
values, duplicate singular fields/conflicting oneofs, invalid wire types,
truncation, oversized/noncanonical varints, invalid booleans and nonfinite
floats. Binary messages are limited to 1 MiB and 32 nested levels. Empty or
arbitrary bytes are not accepted as an empty restore. Strictness intentionally
rejects unsupported future schemas rather than dropping fields. This is format
validation, not authentication: protobuf has no file magic or signature, so a
valid nonempty DeviceProfile cannot be distinguished from another byte stream
that happens to encode the same schema. Session passkeys are never imported.

`verify: true` compares fresh owner/config/module/channel/ringtone/canned-message
responses. Fixed position has **no dedicated Admin getter**: its record reports
`readback: :unsupported`, making the overall status `:readback_incomplete` even
when all available comparisons match. No cached position or config flag is
misrepresented as fixed-position verification. All existing ACK, transaction,
no-replay, secret-handling and persistence limitations apply.

## Transactions and failure reporting

`edit_transaction: true` explicitly sends `begin_edit_settings`, waits for its
ACK, sends each section once with a correlated ACK wait (or matching timeout
readback as described below), then sends
`commit_edit_settings` and waits again. Current upstream
[AdminModule.cpp](https://github.com/meshtastic/firmware/blob/master/src/modules/AdminModule.cpp)
implements a begin flag and commit save of configuration/module/device/channel/
node database segments. Commit also disables Bluetooth. **This is not an atomic
rollback facility**: firmware may apply values before commit, UI has its own
storage operation, and the protocol has no supported cancel/rollback here.
There is no reliable capability probe, so enable this option only with firmware
you have verified supports it. Default `false` avoids claiming universal edit
transaction support.

Result fields:

- `status`: `dry_run`, `acknowledged`, `applied`, `partial_failure`,
  `readback_matched` or `readback_incomplete`. `applied` means all sections
  completed, but at least one required timeout readback instead of an ACK;
  it does not claim every mutation was acknowledged or persisted.
- `planned`, `attempted`, `acknowledged`, `readback_confirmed`: section counts, excluding transaction
  commands and automatic session requests. Attempted is an API attempt and
  does not prove the write reached the wire.
- `plan`: ordered section/slot identities, including in dry runs; no secret values.
- `acknowledged` counts only actual successful setter ACKs. `readback_confirmed`
  counts only setters whose ACK timed out but whose fresh getter matched.
  These counts are separate, never double-counted, and retained on later failure.
- `records`: completed section/slot statuses (`acknowledged` or
  `readback_confirmed`), without configuration values.
- `transaction`: `not_requested`, `begin_uncertain`, `open`, `commit_uncertain`
  or `commit_acknowledged`.
- `failure`: on write/begin/commit failure, the operation, section/slot where
  applicable, exception class and routing reason where available. Exception
  contents and secrets are not included. Failed timeout recovery also includes
  `readback: mismatch|unsupported|failed`; getter exceptions retain their class
  and routing reason where available.
- `warnings`: secret/redaction/persistence limitations.
- `persistence_verified`: always `false`.

Only a section setter's `Timeout::Error` triggers recovery: if a supported
getter exists, import issues one **new**, request-ID/source-correlated Admin GET
with its own per-request timeout. This happens even with `verify: false`.
It continues only if the entire expected protobuf setting matches, using the
same presence-aware comparison as optional verification. Portable owner fields
are compared while generated owner identity/hardware metadata is excluded.
No cached value, unrelated response, late setter ACK, or transport submission
is substituted for that fresh read. The mutation is **never resent**.

Mismatch (including redacted/empty secrets in place of expected nonempty
secrets), absent getter, getter timeout/error, and correlated routing rejection
remain partial failures. Secret fields are not ignored or treated as wildcards;
the report never includes expected/actual values. Firmware normalization can
also prevent exact matching. A matching empty/default value cannot establish
that firmware disclosed a secret; existing backup completeness limitations
still apply. Fixed-position writes have no supported getter. Begin and commit
timeouts do not use this recovery, and routing errors do not trigger it.

After an unresolved failed write, no later sections, commit, rollback or replay are sent.
A transaction may remain open. A missing commit ACK is uncertain even when all
section ACKs arrived; the node may have committed and rebooted. Inspect the
node and establish a fresh connection before deciding on any manual recovery.
Do not automatically rerun the import.

`verify: true` performs another round of fresh correlated reads **after** all
sections complete and any requested commit ACK arrives. Timeout-recovery reads
do not replace this optional post-commit check.
It compares protobuf values (only portable owner fields), adds per-record
`readback: matched|mismatch|failed` and `readback_matched` count. Redaction,
normalization, link loss or reboot can prevent a match. Readback failures never
replay writes. Even a match proves only current reported state, not persistence
across reboot or successful firmware-side storage.

## Verification scope

The automated peer decodes production Serial framing/ToRadio/Admin protobufs,
maintains configuration state, and returns encoded correlated FromRadio Admin
or routing packets through the real Admin queue. Tests cover round-trip bytes
and defaults, dry runs, validation, secret handling, file permissions/symlinks,
ACK failures, timeouts, commit uncertainty, optional readback and help
conventions. No hardware, firmware reboot/persistence, radio-link reliability,
Bluetooth GATT or live TCP endpoint was exercised for this feature.
