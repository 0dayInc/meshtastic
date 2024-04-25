# Meshtastic
Ruby gem for interfacing with Meshtastic nodes.

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
