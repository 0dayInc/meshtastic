# frozen_string_literal: true

require 'meshtastic/mesh_pb'

module Meshtastic
  class Position
    public_class_method def self.build(opts = {})
      position = new
      position.latitude_i = (opts.fetch(:lat).to_f * 10_000_000).round
      position.longitude_i = (opts.fetch(:lon).to_f * 10_000_000).round
      position.altitude = opts[:altitude].to_i if opts[:altitude]
      position.time = opts[:time].to_i if opts[:time]
      position
    end

    public_class_method def self.transmit(opts = {})
      data = Meshtastic::Data.new(
        portnum: :POSITION_APP,
        payload: build(opts).to_proto
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::POSITION_APP))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the build class method for this module.
        #{self}.build(
          altitude: 'optional - value for altitude passed into build',
          time: 'optional - value for time passed into build'
        )

        # Run the transmit class method for this module.
        #{self}.transmit

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
