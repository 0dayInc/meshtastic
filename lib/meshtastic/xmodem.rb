# frozen_string_literal: true

require 'meshtastic/xmodem_pb'

module Meshtastic
  module Xmodem
    def self.encode(opts = {})
      packet = Meshtastic::XModem.new
      packet.control = opts.fetch(:control, :SOH)
      packet.seq = opts[:seq].to_i if opts[:seq]
      packet.buffer = opts[:buffer] if opts[:buffer]
      packet
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.encode(control: :SOH, seq: 1, buffer: data)
        #{self}.authors
      "
    end
  end
end
