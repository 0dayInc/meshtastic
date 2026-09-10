# Meshtastic::Cannedmessages

Wraps `Meshtastic::CannedMessageModuleConfig` (`messages` is a newline-separated string).

## Methods

- `encode(messages:)`
- `send` — publishes the string on `TEXT_MESSAGE_APP` (not an admin set). To store canned lines on the device, use [Admin](admin.md) `set_canned_message_module_messages` or [ModuleConfig](module-config.md).
- `help` / `authors`

## Example

```ruby
cfg = Meshtastic::Cannedmessages.encode(messages: "Yes\nNo\nMaybe")
cfg.messages # => "Yes\nNo\nMaybe"

Meshtastic::Admin.send(
  serial_obj: serial_obj,
  set_canned_message_module_messages: "Yes\nNo\nMaybe"
)
```

## Related

- [Meshtastic::Admin](admin.md)
