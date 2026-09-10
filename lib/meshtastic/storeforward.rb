# frozen_string_literal: true

require 'meshtastic/storeforward_pb'

module Meshtastic
  module Storeforward
    public_class_method def self.encode(opts = {})
      message = Meshtastic::StoreAndForward.new
      message.rr = opts.fetch(:rr, :ROUTER_HEARTBEAT)
      message
    end

    public_class_method def self.send(opts = {})
      data = Meshtastic::Data.new(
        portnum: :STORE_FORWARD_APP,
        payload: encode(opts).to_proto
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::STORE_FORWARD_APP))
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
