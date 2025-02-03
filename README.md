# Meshtastic

Ruby gem for interfacing with Meshtastic nodes / network.

# Setting Expectations

This gem was created to support alt-comm capabilities w/in a security research framework known as [PWN](https://github.com/0dayInc/pwn).  Contributors of this effort cannot guarantee full functionality or support for all Meshtastic features.

# Objectives

- Consume the latest [Meshtastic Protobof Specs](https://github.com/meshtastic/protobufs) and [auto-generate Ruby protobuf modules for Meshtastic](https://github.com/0dayInc/meshtastic/blob/master/AUTOGEN_meshtastic_protobufs.sh) using the `protoc` command: `Complete`
- Integrate auto-generated Ruby protobuf modules into a working Ruby gem: `Complete`
- Scale out Meshtastic Ruby Modules for their respective protobufs within the meshtastic gem (e.g. Meshtastic::MQTTPB is auto-generated based on latest Meshtastic protobuf specs and extended via Meshtastic::MQTT for more MQTT interaction as desired): `Ongoing Effort`

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add meshtastic

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install meshtastic

## Usage

At the moment the only module available is `Meshtastic::MQTT`.  To view MQTT messages, and filter for all messages containing `_APP` _and_ `LongFast` strings, use the following code:

```ruby
require 'meshtastic'
Meshtastic::MQTT.help
mqtt_obj = Meshastic::MQTT.connect
Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj,
  filter: '_APP, LongFast'
)
```

This code will dump the contents of every message:

```ruby
require 'meshtastic'
mqtt_obj = Meshastic::MQTT.connect
Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj,
  region: 'US',
  channel_topic: '2/e/LongFast/#',
  psks: { LongFast: 'AQ==' }
) do |message|
  puts message.inspect
end
```

Sending a message over MQTT:

```ruby
require 'meshtastic'
mqtt_obj = Meshastic::MQTT.connect
client_id = "!#{mqtt_obj.client_id}"
Meshtastic::MQTT.send_text(
  mqtt_obj: mqtt_obj,
  from: client_id,
  to: '!ffffffff',
  topic: "msh/US/2/e/LongFast/#{client_id}",
  channel: 93,
  text: 'Hello, World!',
  psks: { LongFast: 'AQ==' }
)
```

One of the "gotchas" when sending messages is ensuring you're sending over the proper integer for the `channel` parameter.  The best way to determine the proper `channel` value is by sending a test message from within the meshtastic app and then viewing the MQTT message similar to the following:

```ruby
require 'meshtastic'
mqtt_obj = Meshastic::MQTT.connect
Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj,
  region: 'US',
  channel_topic: '2/e/LongFast/#',
  psks: { LongFast: 'AQ==' },
  filter: '!YOUR_CLIENT_ID'
) do |message|
  puts message.inspect
end
```

You should see something like this:

```
{packet: {from: 4080917205, to: 4294967295, channel: 93, id: 1198634591, rx_time: 1738614021, rx_snr: 0.0, hop_limit: 3, want_ack: false, priority: :HIGH, rx_rssi: 0, delayed: :NO_DELAY, via_mqtt: false, hop_start: 3, public_key: "", pki_encrypted: false, next_hop: 0, relay_node: 0, tx_after: 0, decoded: {portnum: :TEXT_MESSAGE_APP, payload: "WHAT IS MY channel VALUE?", want_response: false, dest: 0, source: 0, request_id: 0, reply_id: 0, emoji: 0, bitfield: 0}, encrypted: :decrypted, topic: "msh/US/2/e/LongFast/!f33ddad5", node_id_from: "!f33ddad5", node_id_to: "!ffffffff", rx_time_utc: "2025-01-01 07:00:00 UTC"}, channel_id: "LongFast", gateway_id: "!f33ddad5"}
```

Note where is says `channel: 93`.  This is the `channel` value required to send messages in this particular example.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/0dayinc/meshtastic. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/0dayinc/meshtastic/blob/master/CODE_OF_CONDUCT.md).

## Code of Conduct

Everyone interacting in the Meshtastic project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/0dayinc/meshtastic/blob/master/CODE_OF_CONDUCT.md).
