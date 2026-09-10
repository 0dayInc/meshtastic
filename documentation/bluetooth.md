# Meshtastic::Bluetooth

Linux BLE client (BlueZ + `ruby-dbus`). Same send/receive API as Serial, with `bluetooth_obj:` instead of `serial_obj:`.

Connect with a BLE address (`AA:BB:CC:DD:EE:FF`), not a mesh id (`!11223344`). Pair first; this gem does not guess a PIN. BLE writes unframed `ToRadio` protobufs (no UART `0x94 0xC3` header).

Do not open Serial and Bluetooth to the same radio at once. Disconnect the phone’s Meshtastic BLE session while Linux is connected.

## Methods

- `scan(adapter:, timeout:)`
- `connect(address:, adapter:, timeout:, want_config:)`
- `wait_for_config` — 30 seconds is a reasonable BLE timeout
- `send_text` / `send_data` / `send_to_radio`
- `recv_from_radio` / `drain_from_radio`
- `dump_stdout_data` / `flush_data`
- `subscribe`
- `disconnect`
- `help` / `authors`

## Scan

```ruby
require 'meshtastic'
Meshtastic::Bluetooth.scan(adapter: 'hci0', timeout: 5)
# => [{ address: 'AA:BB:CC:DD:EE:FF', name: 'Meshtastic_eeff', paired: true }, ...]
```

## Pair

Pair while discovery is running. Screen devices typically show a random 6-digit PIN. Do not invent PIN values.

```text
bluetoothctl
agent KeyboardDisplay
default-agent
scan on
pair AA:BB:CC:DD:EE:FF
trust AA:BB:CC:DD:EE:FF
scan off
quit
```

`Failed to pair: AuthenticationFailed` means the agent never got the PIN. `Device … not available` means scan first; the advertisement dropped.

## Send / receive

```ruby
require 'meshtastic'

bluetooth_obj = nil
begin
  bluetooth_obj = Meshtastic::Bluetooth.connect(address: 'AA:BB:CC:DD:EE:FF')
  Meshtastic::Bluetooth.wait_for_config(bluetooth_obj: bluetooth_obj, timeout: 30)

  Meshtastic::Bluetooth.send_text(
    bluetooth_obj: bluetooth_obj,
    to: '!aabbccdd',
    channel: 0,
    text: 'Hello over BLE!',
    want_ack: true
  )

  Meshtastic::Bluetooth.subscribe(
    bluetooth_obj: bluetooth_obj,
    include: 'TEXT_MESSAGE_APP'
  ) do |message|
    packet = message[:packet]
    puts "#{packet[:node_id_from]}: #{packet.dig(:decoded, :payload)}"
  end
ensure
  Meshtastic::Bluetooth.disconnect(bluetooth_obj: bluetooth_obj)
end
```

After an aborted reconnect (`le-connection-abort-by-local`), `bluetoothctl disconnect <addr>` and wait a couple of seconds before `connect` again.

GATT UUIDs (see [BlueZ](bluetooth-bluez.md)):

- Service `6ba1b218-15a8-461f-9fa8-5dcae273eafd`
- ToRadio `f75c76d2-129e-4dad-a1dd-7866124401e7`
- FromRadio `2c55e69e-4993-11ed-b878-0242ac120002`

## Related

- [Meshtastic::Bluetooth::BlueZ](bluetooth-bluez.md)
- [Meshtastic::Serial](serial.md)
