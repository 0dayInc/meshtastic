# Meshtastic
Ruby gem for interfacing with Meshtastic nodes.

# Setting Expectations
This gem was created to support alt-comm capabilities w/in a security research framework known as ('https://github.com/0dayInc/pwn')[PWN].  Contributors of this effort cannot guarantee full functionality or support for all Meshtastic features.

# Objectives
- Consume the ('https://github.com/meshtastic/protobufs')[Meshtastic Protobufs] and ('https://github.com/0dayInc/meshtastic/blob/master/AUTOGEN_meshtastic_protobufs.sh')[generate Ruby protobuf modules for Meshtastic] using the protoc command: Complete
- Integrate a working gem that can interface with the automatically generated Ruby protobuf modules: Complete
- Scale out Meshtastic Ruby Modules for their respective protobufs within the meshtastic gem (e.g. Meshtastic::MQTTPB is auto-generated based on latest Meshtastic protobuf specs and extended via Meshtastic::MQTT for more MQTT interaction as desired): Continued Effort

## Installation

Install the gem and add to the application's Gemfile by executing:

    $ bundle add meshtastic

If bundler is not being used to manage dependencies, install the gem by executing:

    $ gem install meshtastic

## Usage

At the moment the only working module is `Meshtastic::MQTT`.  To view MQTT messages, run the following:

```ruby
require 'meshtastic'
Meshtastic::MQTT.help
mqtt_obj = Meshastic::MQTT.connect
Meshtastic::MQTT.subscribe(mqtt_obj: mqtt_obj)
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/0dayinc/meshtastic. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/[USERNAME]/meshtastic/blob/master/CODE_OF_CONDUCT.md).

## Code of Conduct

Everyone interacting in the Meshtastic project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/[USERNAME]/meshtastic/blob/master/CODE_OF_CONDUCT.md).
