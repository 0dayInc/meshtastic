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
  channel: '2/e/LongFast/#',
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

One of the "gotchas" when sending messages is ensuring you're sending over the proper channel.  The best way to determine which channel you should use is by sending a test message from within the meshtastic app and then viewing the MQTT message similar to the following:

```ruby
require 'meshtastic'
mqtt_obj = Meshastic::MQTT.connect
Meshtastic::MQTT.subscribe(
  mqtt_obj: mqtt_obj,
  region: 'US',
  channel: '2/e/LongFast/#',
  psks: { LongFast: 'AQ==' },
  filter: '!YOUR_CLIENT_ID'
) do |message|
  puts message.inspect
end
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/0dayinc/meshtastic. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/0dayinc/meshtastic/blob/master/CODE_OF_CONDUCT.md).

## Code of Conduct

Everyone interacting in the Meshtastic project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/0dayinc/meshtastic/blob/master/CODE_OF_CONDUCT.md).
