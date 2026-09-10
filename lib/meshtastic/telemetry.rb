# frozen_string_literal: true

require 'meshtastic/telemetry_pb'

module Meshtastic
  class Telemetry
    public_class_method def self.build(opts = {})
      telemetry = new
      telemetry.time = opts[:time].to_i if opts[:time]
      telemetry
    end

    public_class_method def self.request(opts = {})
      data = Meshtastic::Data.new(
        portnum: :TELEMETRY_APP,
        payload: build(opts).to_proto,
        want_response: true
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::TELEMETRY_APP, want_response: true))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the build class method for this module.
        #{self}.build(
          time: 'optional - value for time passed into build'
        )

        # Run the request class method for this module.
        #{self}.request

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
