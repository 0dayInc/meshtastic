# frozen_string_literal: true

require 'meshtastic/mesh_pb'

module Meshtastic
  module Traceroute
    public_class_method def self.encode(opts = {})
      discovery = Meshtastic::RouteDiscovery.new
      Array(opts[:route]).each { |hop| discovery.route << hop }
      discovery
    end

    public_class_method def self.send(opts = {})
      data = Meshtastic::Data.new(
        portnum: :TRACEROUTE_APP,
        payload: encode(opts).to_proto,
        want_response: true
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::TRACEROUTE_APP, want_response: true))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the encode class method for this module.
        #{self}.encode(
          route: 'optional - value for route passed into encode'
        )

        # Run the send class method for this module.
        #{self}.send

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
