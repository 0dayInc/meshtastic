# frozen_string_literal: true

require 'meshtastic/xmodem_pb'

module Meshtastic
  module Xmodem
    public_class_method def self.encode(opts = {})
      packet = Meshtastic::XModem.new
      packet.control = opts.fetch(:control, :SOH)
      packet.seq = opts[:seq].to_i if opts[:seq]
      packet.buffer = opts[:buffer] if opts[:buffer]
      packet
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the encode class method for this module.
        #{self}.encode(
          seq: 'optional - value for seq passed into encode',
          buffer: 'optional - value for buffer passed into encode'
        )

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
