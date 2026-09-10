# frozen_string_literal: true

require 'meshtastic/cannedmessages_pb'

module Meshtastic
  module Cannedmessages
    public_class_method def self.encode(opts = {})
      config = Meshtastic::CannedMessageModuleConfig.new
      config.messages = opts.fetch(:messages, '')
      config
    end

    public_class_method def self.send(opts = {})
      data = Meshtastic::Data.new(
        portnum: :TEXT_MESSAGE_APP,
        payload: encode(opts).messages.to_s.b
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::TEXT_MESSAGE_APP))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the encode class method for this module.
        #{self}.encode

        # Run the send class method for this module.
        #{self}.send

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
