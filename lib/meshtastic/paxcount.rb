# frozen_string_literal: true

require 'meshtastic/paxcount_pb'

module Meshtastic
  class Paxcount
    public_class_method def self.build(opts = {})
      count = new
      count.wifi = opts[:wifi].to_i if opts[:wifi]
      count.ble = opts[:ble].to_i if opts[:ble]
      count.uptime = opts[:uptime].to_i if opts[:uptime]
      count
    end

    public_class_method def self.transmit(opts = {})
      data = Meshtastic::Data.new(
        portnum: :PAXCOUNTER_APP,
        payload: build(opts).to_proto
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::PAXCOUNTER_APP))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the build class method for this module.
        #{self}.build(
          wifi: 'optional - value for wifi passed into build',
          ble: 'optional - value for ble passed into build',
          uptime: 'optional - value for uptime passed into build'
        )

        # Run the transmit class method for this module.
        #{self}.transmit

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
