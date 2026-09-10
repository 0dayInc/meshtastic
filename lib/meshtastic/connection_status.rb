# frozen_string_literal: true

require 'meshtastic/connection_status_pb'

module Meshtastic
  module ConnectionStatus
    def self.decode(bytes)
      Meshtastic::DeviceConnectionStatus.decode(bytes)
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.decode(bytes)
        #{self}.authors
      "
    end
  end
end
