# frozen_string_literal: true

require 'meshtastic/deviceonly_pb'

module Meshtastic
  module Deviceonly
    def self.decode_state(bytes)
      Meshtastic::DeviceState.decode(bytes)
    end

    def self.decode_nodedb(bytes)
      Meshtastic::NodeDatabase.decode(bytes)
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.decode_state(bytes)
        #{self}.decode_nodedb(bytes)
        #{self}.authors
      "
    end
  end
end
