# Meshtastic::Util

Small helpers used by [MeshInterface](mesh-interface.md).

## `Meshtastic::Util::Acknowledgement`

Flags: `received_ack`, `received_nak`, `received_impl_ack`, `received_trace_route`, `received_telemetry`, `received_position`, `received_waypoint`. `#reset` clears them.

## `Meshtastic::Util::Timeout`

`expire_timeout` (default 20 seconds), `expire_time`, `sleep_interval` (0.1). `#reset` sets `expire_time` from now.

## Module methods

- `authors` / `help`

```ruby
ack = Meshtastic::Util::Acknowledgement.new
ack.reset

t = Meshtastic::Util::Timeout.new(expire_timeout: 10)
t.reset
```

## Related

- [Meshtastic::MeshInterface](mesh-interface.md)
