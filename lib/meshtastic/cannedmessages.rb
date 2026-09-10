# frozen_string_literal: true

require 'meshtastic/cannedmessages_pb'

module Meshtastic
  module Cannedmessages
    def self.encode(opts = {})
      config = Meshtastic::CannedMessageModuleConfig.new
      config.messages = opts.fetch(:messages, '')
      config
    end

    def self.send(opts = {})
      data = Meshtastic::Data.new(
        portnum: :TEXT_MESSAGE_APP,
        payload: encode(opts).messages.to_s.b
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::TEXT_MESSAGE_APP))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.encode(messages: \"Yes\\nNo\\nMaybe\")
        #{self}.authors
      "
    end
  end
end
