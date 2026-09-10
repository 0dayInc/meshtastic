# frozen_string_literal: true

require 'meshtastic/connection_status_pb'

module Meshtastic
  module ConnectionStatus
    public_class_method def self.decode(opts = {})
      bytes = opts[:bytes]
      Meshtastic::DeviceConnectionStatus.decode(bytes)
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
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
