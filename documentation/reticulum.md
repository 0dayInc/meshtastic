# Reticulum tunnel (port 76)

```ruby
require 'meshtastic'
frame = Meshtastic::Reticulum.decode_packet(payload: bytes)
packet = Meshtastic::Reticulum.decode_chunks(chunks: explicitly_grouped_wire_strings)
```

This is a **tunnel framing decoder**, not a full Reticulum packet decoder.
No transport is opened, no retransmission is sent, and no state is retained.
The shared receive dispatcher calls `decode_packet` for port 76 on Serial, TCP,
Bluetooth and MQTT, including recursively within simulator wrappers. Malformed
frames preserve their original payload bytes; the direct API raises ArgumentError.

## Verified wire dialect

Primary source: [landandair/RNS_Over_Meshtastic Meshtastic_Interface.py](https://github.com/landandair/RNS_Over_Meshtastic/blob/e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a/Interface/Meshtastic_Interface.py),
revision `e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a`.

* `PacketHandler.struct_format` (line 333) is Python `Bb`: **one unsigned byte
  message index followed by one signed byte position**, exactly two bytes.
  Python's default native struct mode adds no padding between these byte fields;
  byte order has no effect on either single-byte field. Ruby uses `Cc`.
* `split_data` (345–358) starts positions at 1 and negates the last position.
  `-1` is a complete single-fragment message; `-3` is fragment 3 of 3.
  A positive position provides no total count. Zero is invalid.
* `process_message` (239–243, 257 onward) reserves the prefix `REQ`, followed
  by those same two metadata bytes, for retransmission control. Exactly five
  bytes are accepted here. Signed request positions are preserved, with `index`
  exposing their absolute value; upstream lookup accepts either sign.
* The message index wraps modulo 256 (`calc_index`, 419–420).
* Supported bounds follow this pinned interface's default 200-byte fragment
  body and 564-byte hardware MTU (line 102). Wire data is 3–202 bytes: a header
  plus a nonempty body. Reassembly accepts 1–128 fragments and at most 564 body
  bytes. `max_bytes:` on `decode_chunks` can lower, not increase, that ceiling.
  Customized upstream fragment sizes and other port-76 dialects are not claimed.

## Returned values

`decode_packet` returns `format: :reticulum_fragment`, `message_index`, signed
`position`, one-based absolute `index`, `final`, `count` (nil until final),
`complete` (true only for `-1`), `body`, and original binary `raw`.
Even a complete single fragment remains a tunnel frame; body bytes are opaque.
`REQ` returns `format: :reticulum_request`, `message_index`, `position`, `index`,
`complete: false`, and `raw`; it is never treated as packet data.

`decode_chunks` takes original header-bearing String payloads in any order,
including final-first order. It returns `format: :reticulum_packet`,
`complete: true`, `message_index`, `count`, concatenated binary `body`, and
position-sorted `fragments` plus position-sorted original `raw_chunks`.
It rejects missing positions/final markers, multiple final markers, out-of-range
positions, mixed message indexes, requests, all duplicates (including byte-identical
retransmissions), conflicting duplicates, invalid types and size violations with
`ArgumentError`. The caller can explicitly deduplicate identical retransmissions
before submission; this decoder never silently resolves conflicts.

## Grouping and security limits

The caller must isolate connection, channel, sender, message index **and message
generation**, impose expiration and bound its pending queue. Index reuse/wrap is
not detectable from these bytes; same-index fragments from different generations
can be indistinguishable. There is deliberately no global auto-reassembler and no
claim that a consistent index authenticates a group. A missing final fragment
cannot be inferred from arrival order. The reserved `REQ` prefix is ambiguous
with data whose header/body happen to start with those bytes; this implementation
follows upstream's control-prefix precedence and rejects malformed control lengths.

No inner RNS header parsing, decryption, signature verification, destination
interpretation or plaintext claims are implemented. Reassembled bytes are not
necessarily a valid RNS packet. No hardware or installed-gem validation was done.

## Fixtures and tests

`spec/support/reticulum_fixtures.json` contains actual output from executing only
`PacketHandler` extracted via Python AST from the pinned source (no imports of
RNS/meshtastic, hardware access or rewritten splitting algorithm). It records the
source SHA-256. Inputs were opaque `bytes(range(256))*2 + bytes(range(52))` with
index 255, and `b'\x00\xffRNS opaque'` with index 0. Request bytes were generated
with the upstream `struct_format` and `b'REQ' + struct.pack(..., 255, 2)`.
These are real upstream-encoder framing fixtures, **not captured radio traffic or
valid-RNS-packet fixtures**. Python is not a runtime dependency of the Ruby module.

Specs exercise these fixtures, signed extrema, strict malformed inputs,
final-first grouping, duplicate/conflict/missing/control rejection, and aggregate
limits. Shared transport fixtures cover an upstream single fragment, REQ control,
malformed byte preservation and a simulator-wrapped fragment over all four receive
boundaries (MQTT both decoded and AES-encrypted). The JSON vectors are included in
the gem manifest even without a Git file listing. New behavior was exercised with
failing tests before implementation.
