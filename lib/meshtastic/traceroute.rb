# frozen_string_literal: true

require 'meshtastic/mesh_pb'

module Meshtastic
  module Traceroute
    def self.encode(opts = {})
      discovery = Meshtastic::RouteDiscovery.new
      Array(opts[:route]).each { |hop| discovery.route << hop }
      discovery
    end

    def self.send(opts = {})
      data = Meshtastic::Data.new(
        portnum: :TRACEROUTE_APP,
        payload: encode(opts).to_proto,
        want_response: true
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::TRACEROUTE_APP, want_response: true))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.send(serial_obj: serial_obj, to: '!aabbccdd')
        #{self}.authors
      "
    end
  end
end
