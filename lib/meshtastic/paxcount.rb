# frozen_string_literal: true

require 'meshtastic/paxcount_pb'

module Meshtastic
  class Paxcount
    def self.build(opts = {})
      count = new
      count.wifi = opts[:wifi].to_i if opts[:wifi]
      count.ble = opts[:ble].to_i if opts[:ble]
      count.uptime = opts[:uptime].to_i if opts[:uptime]
      count
    end

    def self.transmit(opts = {})
      data = Meshtastic::Data.new(
        portnum: :PAXCOUNTER_APP,
        payload: build(opts).to_proto
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::PAXCOUNTER_APP))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.transmit(serial_obj: serial_obj, wifi: 3, ble: 2)
        #{self}.authors
      "
    end
  end
end
