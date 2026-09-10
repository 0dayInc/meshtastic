# frozen_string_literal: true

require 'meshtastic/atak_pb'

module Meshtastic
  module ATAK
    def self.encode(opts = {})
      packet = Meshtastic::TAKPacket.new
      packet.is_compressed = opts.fetch(:is_compressed, false)
      if opts[:chat]
        packet.chat = opts[:chat]
      elsif opts[:message]
        packet.chat = Meshtastic::GeoChat.new(message: opts[:message])
      end
      packet
    end

    def self.send(opts = {})
      data = Meshtastic::Data.new(
        portnum: :ATAK_PLUGIN,
        payload: encode(opts).to_proto
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::ATAK_PLUGIN))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.send(serial_obj: serial_obj, message: 'ATAK chat')
        #{self}.authors
      "
    end
  end
end
