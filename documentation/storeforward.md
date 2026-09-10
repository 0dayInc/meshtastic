# Meshtastic::Storeforward

Sends `Meshtastic::StoreAndForward` on `STORE_FORWARD_APP` (port 65).

## Methods

- `encode(rr:)` — request/response enum, default `:ROUTER_HEARTBEAT`
- `send`
- `help` / `authors`

`rr` includes values such as `:CLIENT_HISTORY`, `:ROUTER_HEARTBEAT`.

## Example

```ruby
Meshtastic::Storeforward.send(
  serial_obj: serial_obj,
  rr: :CLIENT_HISTORY
)
```

## Related

- [Meshtastic::ModuleConfig](module-config.md) (`:STOREFORWARD_CONFIG`)
