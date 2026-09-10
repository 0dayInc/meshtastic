# frozen_string_literal: true

require 'meshtastic/telemetry_pb'

module Meshtastic
  class Telemetry
    def self.build(opts = {})
      telemetry = new
      telemetry.time = opts[:time].to_i if opts[:time]
      telemetry
    end

    def self.request(opts = {})
      data = Meshtastic::Data.new(
        portnum: :TELEMETRY_APP,
        payload: build(opts).to_proto,
        want_response: true
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::TELEMETRY_APP, want_response: true))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.request(serial_obj: serial_obj, to: '!aabbccdd')
        #{self}.authors
      "
    end
  end
end
