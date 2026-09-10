# frozen_string_literal: true

require 'meshtastic/apponly_pb'

module Meshtastic
  module Apponly
    public_class_method def self.encode(opts = {})
      set = Meshtastic::ChannelSet.new
      Array(opts[:settings]).each { |channel| set.settings << channel }
      set.lora_config = opts[:lora_config] if opts[:lora_config]
      set
    end

    public_class_method def self.decode(opts = {})
      bytes = opts[:bytes]
      Meshtastic::ChannelSet.decode(bytes)
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the encode class method for this module.
        #{self}.encode(
          settings: 'optional - value for settings passed into encode',
          lora_config: 'optional - value for lora_config passed into encode'
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
