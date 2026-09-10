# frozen_string_literal: true

require 'meshtastic/portnums_pb'

module Meshtastic
  module Portnums
    def self.lookup(name_or_number)
      if name_or_number.is_a?(Integer)
        Meshtastic::PortNum.lookup(name_or_number)
      else
        Meshtastic::PortNum.resolve(name_or_number.to_sym)
      end
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.lookup(:TEXT_MESSAGE_APP)
        #{self}.lookup(1)
        #{self}.authors
      "
    end
  end
end
