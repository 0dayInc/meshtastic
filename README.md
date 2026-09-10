# Meshtastic

Ruby gem for interfacing with Meshtastic nodes / network.

# Setting Expectations

This gem was created to support alt-comm capabilities w/in a security research framework known as [PWN](https://github.com/0dayInc/pwn).  Contributors of this effort cannot guarantee full functionality or support for all Meshtastic features.

# Objectives

- Consume the latest [Meshtastic Protobof Specs](https://github.com/meshtastic/protobufs) and [auto-generate Ruby protobuf modules for Meshtastic](https://github.com/0dayInc/meshtastic/blob/master/AUTOGEN_meshtastic_protobufs.sh) using the `grpc_tools_ruby_protoc` command: `Complete`
- Integrate auto-generated Ruby protobuf modules into a working Ruby gem: `Complete`
- Scale out Meshtastic Ruby Modules for their respective protobufs within the meshtastic gem (e.g. Meshtastic::MQTTPB is auto-generated based on latest Meshtastic protobuf specs and extended via Meshtastic::MQTT for more MQTT interaction as desired): `Ongoing Effort`

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add meshtastic

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install meshtastic

## Usage

The primary interaction modules today are `Meshtastic::MQTT` (broker), `Meshtastic::Serial` (USB/UART), and `Meshtastic::Bluetooth` (BLE via Linux BlueZ). Examples for each follow.

### MQTT

To view MQTT messages, and include only messages containing `_APP` _and_ `LongFast` strings, use the following code:

```ruby
require 'meshtastic'
Meshtastic::MQTT.help
mqtt_obj = Meshtastic::MQTT.connect
puts mqtt_obj.inspect
Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj,
  include: '_APP, LongFast'
)
```

This code will dump the contents of every message:

```ruby
require 'meshtastic'
mqtt_obj = Meshtastic::MQTT.connect
Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj,
  root_topic: 'msh',
  region: 'US',
  topic: '2/e/LongFast/#',
  psks: { LongFast: 'AQ==' }
) do |message|
  puts message.inspect
end
```

Sending a message over MQTT:

```ruby
require 'meshtastic'
mqtt_obj = Meshtastic::MQTT.connect
client_id = "!#{mqtt_obj.client_id}"
Meshtastic::MQTT.send_text(
  mqtt_obj: mqtt_obj,
  from: client_id,
  to: '!ffffffff',
  root_topic: 'msh',
  region: 'US',
  topic: '2/e/LongFast/#',
  channel: 93,
  text: 'Hello, World!',
  psks: { LongFast: 'AQ==' }
)
```

One of the "gotchas" when sending messages is ensuring you're sending over the proper integer for the `channel` parameter.  The best way to determine the proper `channel` value is by sending a test message from within the meshtastic app and then viewing the MQTT message similar to the following:

```ruby
require 'meshtastic'
mqtt_obj = Meshtastic::MQTT.connect
Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj,
  root_topic: 'msh',
  region: 'US',
  topic: '2/e/LongFast/#',
  psks: { LongFast: 'AQ==' },
  include: '!YOUR_CLIENT_ID'
) do |message|
  puts message.inspect
end
```

You should see something like this:

```
{packet: {from: 3237997296, to: 4294967295, channel: 93, id: 1, rx_time: 1735689600, rx_snr: 0.0, hop_limit: 3, want_ack: false, priority: :HIGH, rx_rssi: 0, delayed: :NO_DELAY, via_mqtt: false, hop_start: 3, public_key: "", pki_encrypted: false, next_hop: 0, relay_node: 0, tx_after: 0, decoded: {portnum: :TEXT_MESSAGE_APP, payload: "WHAT IS MY channel VALUE?", want_response: false, dest: 0, source: 0, request_id: 0, reply_id: 0, emoji: 0, bitfield: 0}, encrypted: :decrypted, topic: "msh/US/2/e/LongFast/!c0ffee00", node_id_from: "!c0ffee00", node_id_to: "!ffffffff", rx_time_utc: "2025-01-01 00:00:00 UTC"}, channel_id: "LongFast", gateway_id: "!c0ffee00"}
```

Note where is says `channel: 93`.  This is the `channel` value required to send messages in this particular example.

### Serial and Bluetooth (send / receive)

`Meshtastic::Serial` (USB/UART) and `Meshtastic::Bluetooth` (Linux BLE via BlueZ) talk to a local radio using the same client API. The radio encrypts with its configured channel keys. Payloads are sent decoded; `channel:` is the index on the device, not an MQTT channel hash.

Do not open Serial and Bluetooth to the same radio at once. Disconnect when finished (`ensure` is the reliable pattern). `send_text` / `send_data` report bytes written, not mesh delivery. `want_ack: true` requests a `ROUTING_APP` acknowledgment (`error_reason: NONE` means the local radio accepted the route). Incoming text is a UTF-8 string under `message[:packet][:decoded][:payload]`.

Call `wait_for_config` before using `my_node_num` or sending. It raises `Timeout::Error` if the firmware never completes the handshake. Opening a port or pairing is not the same as a completed handshake.

#### Serial (`Meshtastic::Serial`)

Use the device’s USB CDC port (`/dev/ttyACM*` or `/dev/ttyUSB*`). Enable Radio Configuration → Security → Serial Console (`security.serial_enabled`). That is not Module Configuration → Serial (`TEXTMSG` / `PROTO` on GPIO). Keep “Override Console Serial Port” off.

```ruby
require 'meshtastic'

serial_obj = nil
begin
  serial_obj = Meshtastic::Serial.connect(block_dev: '/dev/ttyACM0', baud: 115_200)
  Meshtastic::Serial.wait_for_config(serial_obj: serial_obj, timeout: 10)
  puts "local node: !#{serial_obj[:my_node_num].to_s(16)}"

  # Direct message, or to: '!ffffffff' for the shared channel.
  Meshtastic::Serial.send_text(
    serial_obj: serial_obj,
    to: '!aabbccdd',
    channel: 0,
    text: 'Hello over serial!',
    want_ack: true
  )

  Meshtastic::Serial.subscribe(
    serial_obj: serial_obj,
    include: 'TEXT_MESSAGE_APP'
  ) do |message|
    packet = message[:packet]
    puts "#{packet[:node_id_from]}: #{packet.dig(:decoded, :payload)}"
  end
ensure
  Meshtastic::Serial.disconnect(serial_obj: serial_obj)
end
```

Drive the loop yourself with `recv_from_radio(serial_obj:, timeout:)` (`0` polls, `nil` blocks) or `drain_from_radio`. A closed empty queue returns `nil`; an unplugged device raises `IOError`. If `wait_for_config` times out, the USB path is up but the Stream API is not (wrong port, Serial Console disabled, or firmware not responding).

#### Bluetooth (`Meshtastic::Bluetooth`)

Linux only (BlueZ + `ruby-dbus`). Connect with a BLE address (`AA:BB:CC:DD:EE:FF`), not a mesh id (`!11223344`). Pair first; this gem does not guess a PIN. BLE writes unframed ToRadio protobufs (no UART `0x94 0xC3` header).

Scan:

```ruby
require 'meshtastic'
Meshtastic::Bluetooth.scan(adapter: 'hci0', timeout: 5)
# => [{ address: 'AA:BB:CC:DD:EE:FF', name: 'Meshtastic_eeff', paired: true }, ...]
```

Pair while discovery is running. Screen devices typically show a random 6-digit PIN:

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

Send and receive (same options as Serial, `bluetooth_obj:` instead of `serial_obj:`):

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

Disconnect the phone’s Meshtastic BLE session while Linux is connected. After an aborted reconnect (`le-connection-abort-by-local`), `bluetoothctl disconnect <addr>` and wait a couple of seconds before `connect` again. Config dumps over BLE can take longer than serial; 30 seconds is a reasonable `wait_for_config` timeout.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/0dayinc/meshtastic. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/0dayinc/meshtastic/blob/master/CODE_OF_CONDUCT.md).

## Code of Conduct

Everyone interacting in the Meshtastic project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/0dayinc/meshtastic/blob/master/CODE_OF_CONDUCT.md).
