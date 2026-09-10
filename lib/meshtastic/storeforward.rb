# frozen_string_literal: true

require 'meshtastic/storeforward_pb'

module Meshtastic
  module Storeforward
    def self.encode(opts = {})
      message = Meshtastic::StoreAndForward.new
      message.rr = opts.fetch(:rr, :ROUTER_HEARTBEAT)
      message
    end

    def self.send(opts = {})
      data = Meshtastic::Data.new(
        portnum: :STORE_FORWARD_APP,
        payload: encode(opts).to_proto
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::STORE_FORWARD_APP))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.send(serial_obj: serial_obj, rr: :CLIENT_HISTORY)
        #{self}.authors
      "
    end
  end
end
