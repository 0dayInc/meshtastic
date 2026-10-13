# Meshtastic::Waypoint

`Waypoint` remains the generated protobuf **class**. `build(fields:)` and `transmit` add validated waypoint/geofence helpers without replacing its constructor, descriptor, encoder, or decoder. All methods accept one options Hash; `help` and `authors` expose usage and attribution.

## Circle and box examples

```ruby
circle = Meshtastic::Waypoint.build(fields: {
  id: 7, name: 'Meeting point',
  latitude_i: 450_000_000, longitude_i: -730_000_000,
  geofence_radius: 100,
  notify_on_enter: true, notify_on_exit: true,
  notify_favorites_only: true
})

box = Meshtastic::Waypoint.build(fields: {
  id: 8, name: 'Search area',
  bounding_box: {
    longitude_west_i: -731_000_000, latitude_south_i: 449_000_000,
    longitude_east_i: -729_000_000, latitude_north_i: 451_000_000
  },
  notify_on_enter: true
})

Meshtastic::Waypoint.transmit(serial_obj: connection, waypoint: circle, want_ack: true)
# Alternative: pass fields: directly, not both waypoint and fields.
```

Coordinates are **integer decimal degrees × 10,000,000**, not radians, floating-point degrees, or map pixels. Latitude must be within ±900,000,000 and longitude within ±1,800,000,000. Supply waypoint latitude and longitude together, including explicit zero for equator/prime-meridian locations. A positive radius requires that center. `geofence_radius` is uint32 meters; zero means no circular fence.

`bounding_box` uses exactly `longitude_west_i`, `latitude_south_i`, `longitude_east_i`, `latitude_north_i` (west/south/east/north), with south ≤ north and west ≤ east. Antimeridian-spanning boxes must be split; they are not silently reordered. An explicitly empty box is valid proto3 and denotes all-zero bounds. Circle and box may coexist, as allowed by the pinned schema.

Notification flags are booleans: `notify_on_enter`, `notify_on_exit`, `notify_favorites_only`. Favorite status is resolved **locally on each receiving device**. These are firmware/client notification instructions, not a host tracking service or a guarantee that every device will alert.

## Other fields and validation

Only exact generated `Waypoint` fields are accepted under `fields:`. In addition to the geometry/notification fields, these are `id`, `expire` (Unix seconds), `locked_to` (editing node number, zero for unrestricted), `name`, `description`, and `icon` (Unicode designator integer). There is no invented `shape`, `radius`, `receive_only`, or `geofence` wire field. The helper rejects unknown fields, invalid types, out-of-range numbers, nil values, geographic bounds violations, incomplete centers, and reversed boxes before transmission.

Pinned nanopb storage allows **29 UTF-8 bytes for name and 99 for description**, leaving the terminating byte inside the schema's 30/100-byte storage buffers. Overlength text, embedded NUL, and invalid UTF-8 are rejected, never truncated. `build` without fields and a decoded empty proto3 message are valid default waypoints; absence of payload bytes does not mean a malformed known protobuf payload.

## Transmission and limits

`transmit(waypoint:)` revalidates even an object made directly with `Waypoint.new`, then submits `Data(portnum: :WAYPOINT_APP)` through `Meshtastic.deliver_data`. Use the existing non-Admin transport keywords: `serial_obj`, `bluetooth_obj`, `tcp_obj`, or `mqtt_obj`. Shared transport options such as destination, channel, hop limit, packet ID, `want_ack`, `pki_encrypted`, and `public_key` pass through unchanged. For MQTT use `channel_id` and `psks` per the [MQTT](mqtt.md) documentation; MQTT PKI remains unsupported. Do not supply multiple transport handles.

Submission is not an RF receipt or notification confirmation. Signing reports, ACK proofs, and broker claims are different evidence; see [Admin delivery results](admin.md#delivery-evidence-and-trust-boundary-v2818e6a88d). Geofence handling and UI notifications depend on the receiver's firmware/build. No live radio verification was performed.

## Pinned contract

Firmware **v2.8.1.8e6a88d**, commit `8e6a88d06f44cad26f1e8d7cd402939ccacb9b4c`, pins protobuf commit `8f97d66a63ce10cfb12f94203e361691647f5ad3`:

- [Waypoint and BoundingBox schema](https://github.com/meshtastic/protobufs/blob/8f97d66a63ce10cfb12f94203e361691647f5ad3/meshtastic/mesh.proto)
- [Firmware string capacities](https://github.com/meshtastic/protobufs/blob/8f97d66a63ce10cfb12f94203e361691647f5ad3/meshtastic/mesh.options)

Related: [Position](position.md), [Admin::Config](admin-config.md).
