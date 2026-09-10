# frozen_string_literal: true

require 'meshtastic/apponly_pb'

module Meshtastic
  module Apponly
    def self.encode(opts = {})
      set = Meshtastic::ChannelSet.new
      Array(opts[:settings]).each { |channel| set.settings << channel }
      set.lora_config = opts[:lora_config] if opts[:lora_config]
      set
    end

    def self.decode(bytes)
      Meshtastic::ChannelSet.decode(bytes)
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.encode(settings: [Meshtastic::ChannelSettings.new])
        #{self}.decode(bytes)
        #{self}.authors
      "
    end
  end
end
