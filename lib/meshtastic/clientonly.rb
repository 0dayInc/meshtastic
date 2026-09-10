# frozen_string_literal: true

require 'meshtastic/clientonly_pb'

module Meshtastic
  module Clientonly
    def self.encode(opts = {})
      profile = Meshtastic::DeviceProfile.new
      profile.long_name = opts[:long_name].to_s if opts[:long_name]
      profile.short_name = opts[:short_name].to_s if opts[:short_name]
      profile
    end

    def self.decode(bytes)
      Meshtastic::DeviceProfile.decode(bytes)
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.encode(long_name: 'Node', short_name: 'N1')
        #{self}.decode(bytes)
        #{self}.authors
      "
    end
  end
end
