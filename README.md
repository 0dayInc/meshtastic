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

All usage examples live under [documentation/](documentation/README.md): transports (MQTT, Serial, Bluetooth, TCP), Admin and other feature modules, internals, and generated protobuf types.

```ruby
require 'meshtastic'
Meshtastic.help          # constants in the namespace
Meshtastic::Serial.help  # methods for one module
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/0dayinc/meshtastic. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/0dayinc/meshtastic/blob/master/CODE_OF_CONDUCT.md).

## Code of Conduct

Everyone interacting in the Meshtastic project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/0dayinc/meshtastic/blob/master/CODE_OF_CONDUCT.md).
