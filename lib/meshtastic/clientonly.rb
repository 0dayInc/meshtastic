# frozen_string_literal: true

require 'meshtastic/clientonly_pb'

module Meshtastic
  module Clientonly
    public_class_method def self.encode(opts = {})
      profile = Meshtastic::DeviceProfile.new
      profile.long_name = opts[:long_name].to_s if opts[:long_name]
      profile.short_name = opts[:short_name].to_s if opts[:short_name]
      profile
    end

    public_class_method def self.decode(opts = {})
      bytes = opts[:bytes]
      Meshtastic::DeviceProfile.decode(bytes)
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the encode class method for this module.
        #{self}.encode(
          long_name: 'optional - value for long_name passed into encode',
          short_name: 'optional - value for short_name passed into encode'
        )

        # Run the decode class method for this module.
        #{self}.decode(
          bytes: 'optional - value for bytes passed into decode'
        )

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
