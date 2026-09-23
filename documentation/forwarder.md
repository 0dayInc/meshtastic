# ATAK Forwarder (port 257)

`require 'meshtastic/forwarder'` loads a Ruby decoder independent of ATAK V1/V2.
The caller must preserve the original payload when decoding fails.

```ruby
# One actual port-257 packet, including the chunk header:
result = Meshtastic::Forwarder.decode_packet(payload: bytes)

# A complete explicitly grouped set of header-bearing chunks (any order):
result = Meshtastic::Forwarder.decode_chunks(chunks: chunks)

# Already reassembled libcotshrink bytes, without the chunk header:
result = Meshtastic::Forwarder.decode(payload: bytes)
```

## Implemented support and precise limits

* `:libcotshrink_protobuf` results contain `:protobuf`, a schema-level hash
  covering the complete 43-file upstream CoT descriptor graph, including all
  22 Detail fields, nested shapes, routes, GeoChat, video, sensors and medevac.
  This is **not** Meshtastic TAKPacket or standard TAK Protocol CotEvent.
* `:event` additionally interprets UID, omitted PLI type, scaled latitude and
  longitude, CE/LE, packed HAE, time offset and stale interval. `:extensions`
  interprets all 16 customBytesExt fields, including nullable values and mapped
  strings. These conversions follow libcotshrink's own converters.
* Nested Detail values remain **schema-level encoded values**: this module does
  not implement all per-detail scaling, string substitutions, defaults or CoT
  XML reconstruction. A decoded protobuf hash is not a full reconstructed CoT
  event. The packed source values remain in `:protobuf`.
* Optional GZIP wrapping is detected by its magic bytes. Both compressed input
  and decompressed output are bounded by `max_bytes` (default and hard ceiling
  1,048,576). Malformed/truncated GZIP and trailing bytes are rejected. Plain
  zlib/DEFLATE is not the libcotshrink wrapper.
* Year and timezone are **not transmitted**. Upstream derives its epoch using
  local `Calendar`, January 1 of its startup year. Without context the decoder
  returns `time_offset_seconds` and `stale_after_seconds`; it does not guess.
  Supply `start_of_year: Time.new(2025, 1, 1, 0, 0, 0, '+00:00')` only when the
  sender's epoch is known. Then `time`, `start`, and `stale` are emitted as UTC
  ISO 8601 strings. This matters for archived messages and New Year boundaries.
* Invalid mapped values, malformed protobuf, and size violations raise
  `ArgumentError`. EXI raises `Meshtastic::Forwarder::UnsupportedFormat`, a
  subclass of `ArgumentError`. Empty reassembled bytes remain a valid default
  proto3 message; an empty radio packet lacks its mandatory chunk header.

### Framing is not optional

Upstream MeshSender prepends **one byte**: high nibble is zero-based chunk
index, low nibble is total chunk count (1–15). Its normal chunk body is at most
200 bytes. Even an unfragmented message begins with `0x01`, **not `0x00`**.
`decode_packet` strips that byte and decodes a single-chunk message. For a
multi-chunk message it returns `format: :forwarder_fragment`, `index`, `count`,
and binary `body`; it never treats a fragment as a complete protobuf.

`decode_chunks` requires every index exactly once with a consistent count,
rejects missing/duplicate chunks, orders the chunks, bounds aggregate bytes,
and decodes only after reassembly. It is deliberately stateless. Integration
must group by connection/channel/sender and impose a short lifetime and a
bounded queue. The upstream header has **no message ID**, so concurrent
same-sender messages cannot be disambiguated reliably from payload bytes.
Do not silently merge unrelated generations. A Meshtastic packet ID identifies
one radio packet, not all chunks of an application message.

`ATAKBCAST,mesh-id,uid,callsign,initial` discovery broadcasts are returned as
`:forwarder_discovery`, not sent through a CoT decoder.

## EXI blocker — full Forwarder decoding is not complete

libcotshrink's lossless mode uses EXIficient `DefaultEXIFactory.newInstance()`;
its lossy mode falls back to that mode for unsupported CoT details. Either can
be GZIP wrapped. No XSD is supplied: the required format is schema-less EXI,
not a fixed CoT field table. Real support needs EXI header/options handling,
bit-level event codes, dynamically learned XML grammars, QName/string-table
partitions and EXI datatype decoding. A zlib inflater or protobuf schema cannot
replace this engine.

This implementation recognizes the EXI distinguishing bits/cookie and fails
explicitly. No working Ruby EXI engine or captured EXI wire fixture was found
in this research. That is an implementation/dependency gap, not a claim that
EXI is mathematically impossible in Ruby. The superficially named `xi_parser`
gem is a personal-wiki-to-HTML parser, not EXI. No Java or Python subprocess is
used; full EXI support remains unimplemented.

## Provenance and verification

The generated `forwarder_pb.rb` embeds FileDescriptorProto bytes from
`paulmandal/libcotshrink` revision
`7d818b0d119a8df291770923b463fbb734b7e1b0`. They were produced with `protoc
--include_imports --descriptor_set_out=... cotevent.proto` and registered in a
private Ruby DescriptorPool in dependency order. The upstream MIT license is
included in that generated file. Runtime requires neither protoc nor the
Android libraries.

Specs include an independent `protoc --encode` wire fixture, direct
hand-authored wire, packed-bit/null handling, nested schema decoding, actual
nibble framing, shuffled reassembly, missing/duplicate fragments, discovery,
GZIP and output limits. These are schema-conformance fixtures, **not captured
radio packets**. Upstream `HackyTests.java` supplies CoT XML test inputs and
Android runtime round-trip tests, not checked-in binary fixtures. The Android
implementation was inspected but not executed, and interoperability with live
hardware is not claimed.

Primary implementation sources:

* [CotShrinker format selection and GZIP](https://github.com/paulmandal/libcotshrink/blob/7d818b0d119a8df291770923b463fbb734b7e1b0/src/main/java/com/paulmandal/atak/libcotshrink/pub/api/CotShrinker.java)
* [CoT schema](https://github.com/paulmandal/libcotshrink/blob/7d818b0d119a8df291770923b463fbb734b7e1b0/src/main/proto/cotevent.proto)
* [Detail schema graph](https://github.com/paulmandal/libcotshrink/blob/7d818b0d119a8df291770923b463fbb734b7e1b0/src/main/proto/detail/detail.proto)
* [Packed time/height](https://github.com/paulmandal/libcotshrink/blob/7d818b0d119a8df291770923b463fbb734b7e1b0/src/main/java/com/paulmandal/atak/libcotshrink/protobuf/CustomBytesConverter.java)
* [Packed extensions/mappings](https://github.com/paulmandal/libcotshrink/blob/7d818b0d119a8df291770923b463fbb734b7e1b0/src/main/java/com/paulmandal/atak/libcotshrink/protobuf/CustomBytesExtConverter.java)
* [Nullable bit semantics](https://github.com/paulmandal/libcotshrink/blob/7d818b0d119a8df291770923b463fbb734b7e1b0/src/main/java/com/paulmandal/atak/libcotshrink/protobuf/utils/BitUtils.java)
* [Local-year epoch](https://github.com/paulmandal/libcotshrink/blob/7d818b0d119a8df291770923b463fbb734b7e1b0/src/main/java/com/paulmandal/atak/libcotshrink/protobuf/cotevent/CotEventProtobufConverterFactory.java)
* [EXI configuration](https://github.com/paulmandal/libcotshrink/blob/7d818b0d119a8df291770923b463fbb734b7e1b0/src/main/java/com/paulmandal/atak/libcotshrink/exi/ExiConverterFactory.java), [EXI standard](https://www.w3.org/TR/exi/)
* [Forwarder chunk construction](https://github.com/paulmandal/atak-forwarder/blob/ad47f2c69e45785eb6029945be232bc52acd695c/app/src/main/java/com/paulmandal/atak/forwarder/comm/meshtastic/MeshSender.java)
* [Forwarder chunk reception](https://github.com/paulmandal/atak-forwarder/blob/ad47f2c69e45785eb6029945be232bc52acd695c/app/src/main/java/com/paulmandal/atak/forwarder/comm/meshtastic/InboundMeshMessageHandler.java)
* [Upstream XML tests](https://github.com/paulmandal/libcotshrink/blob/7d818b0d119a8df291770923b463fbb734b7e1b0/src/main/java/com/paulmandal/atak/libcotshrink/hackytests/HackyTests.java)

## Read-only fragmentation assessment: ports 76 and 75

### Reticulum tunnel (76)

The inspected [RNS Meshtastic interface, revision e5eb5d23](https://github.com/landandair/RNS_Over_Meshtastic/blob/e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a/Interface/Meshtastic_Interface.py)
uses a two-byte `Bb` header: unsigned message index and signed fragment
position. Positions start at 1; a negative position marks the final fragment
and its absolute value is the total count. `REQ` followed by the same two-byte
metadata requests retransmission; it is not RNS packet data. Reassembly must
key by sender and message index (plus connection/channel isolation), wait for
every position through the known last index, strip headers, and only then
parse the RNS packet. Out-of-order final-first delivery, duplicate conflicts,
index wrap/reuse, timeouts, maximum packet bytes and bounded state all need
coverage. An encrypted RNS inner payload cannot be made plaintext by tunnel
reassembly. This assessment does not assert every third-party port-76 sender
uses this identical protocol. [Reticulum](reticulum.md) implements this pinned
tunnel framing and explicitly grouped, bounded reassembly; the receive dispatcher
decodes individual frames only. Inner RNS parsing and decryption remain unsupported.

### LoRaWAN bridge (75)

The [pinned authoritative bridge protobuf](https://github.com/meshtastic/protobufs/blob/51028ca5a6945c76d3977c2bb803f9947d319ac5/meshtastic/lorawan_bridge.proto)
explicitly defines fragmentation: Uplink/Downlink `chunk_count == 0` is a full
PHY frame; `chunk_count == 2` means `payload` is its first part and `payload_id`
is 1–255. A separate `PayloadChunk` has the same ID, `chunk_index == 1` and the
remaining `payload_chunk`. Reassembly keys on sender and payload ID; retain
head RF metadata, append exactly one continuation and reject other counts or
indexes. Isolate connections/channels/directions, expire incomplete entries,
handle continuation-before-head, and reject conflicting duplicates. This is
not the RNS signed-position format. Only the reassembled LoRaWAN PHYPayload
should reach a LoRaWAN frame parser; application plaintext also needs the
correct LoRaWAN security context. TxResult correlates by `request_id`, not
`tmst`. No LoRaWAN transport/reassembly code was changed.
