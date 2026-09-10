# frozen_string_literal: true

require 'meshtastic/deviceonly_pb'

module Meshtastic
  module Deviceonly
    public_class_method def self.decode_state(opts = {})
      bytes = opts[:bytes]
      Meshtastic::DeviceState.decode(bytes)
    end

    public_class_method def self.decode_nodedb(opts = {})
      bytes = opts[:bytes]
      Meshtastic::NodeDatabase.decode(bytes)
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the decode_state class method for this module.
        #{self}.decode_state(
          bytes: 'optional - value for bytes passed into decode_state'
        )

        # Run the decode_nodedb class method for this module.
        #{self}.decode_nodedb(
          bytes: 'optional - value for bytes passed into decode_nodedb'
        )

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
