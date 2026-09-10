# Meshtastic::Bluetooth::BlueZ

Linux D-Bus backend used by [Meshtastic::Bluetooth](bluetooth.md). You normally call `Meshtastic::Bluetooth.scan` / `connect` instead of this class.

## Constants

- `SERVICE_UUID`
- `TORADIO_UUID`
- `FROMRADIO_UUID`

## Methods

- `BlueZ.scan(adapter: 'hci0', timeout: 5)` — `StartDiscovery` then list Device1 objects on that adapter. Returns `{ address:, name:, paired: }`.
- `#connect` — requires an already paired device; raises if not paired or `ServicesResolved` times out
- `#read` / write ToRadio characteristic
- `#close`

Requires `ruby-dbus`. Uses the system bus. D-Bus calls are serialized on a mutex.

```ruby
require 'meshtastic'

hits = Meshtastic::Bluetooth::BlueZ.scan(adapter: 'hci0', timeout: 5)
hits.each { |d| puts "#{d[:address]} #{d[:name]} paired=#{d[:paired]}" }

conn = Meshtastic::Bluetooth::BlueZ.new(address: 'AA:BB:CC:DD:EE:FF', adapter: 'hci0', timeout: 15)
conn.connect
conn.close
```

Pairing is outside this class (`bluetoothctl`). The module will not try PIN values.

## Related

- [Meshtastic::Bluetooth](bluetooth.md)
