# frozen_string_literal: true

require 'meshtastic/mesh_pb'

module Meshtastic
  class Position
    def self.build(opts = {})
      position = new
      position.latitude_i = (opts.fetch(:lat).to_f * 10_000_000).round
      position.longitude_i = (opts.fetch(:lon).to_f * 10_000_000).round
      position.altitude = opts[:altitude].to_i if opts[:altitude]
      position.time = opts[:time].to_i if opts[:time]
      position
    end

    def self.transmit(opts = {})
      data = Meshtastic::Data.new(
        portnum: :POSITION_APP,
        payload: build(opts).to_proto
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::POSITION_APP))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.transmit(serial_obj: serial_obj, lat: 37.7749, lon: -122.4194, altitude: 10)
        #{self}.authors
      "
    end
  end
end
