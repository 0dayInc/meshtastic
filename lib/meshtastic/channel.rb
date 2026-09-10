# frozen_string_literal: true

require 'meshtastic/channel_pb'

module Meshtastic
  class Channel
    def self.get(opts = {})
      Admin.get_channel(opts)
    end

    def self.set(opts = {})
      channel = opts[:channel] || opts[:channel_settings] || new
      Admin.set_channel(opts.merge(channel_settings: channel))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.get(serial_obj: serial_obj, index: 0)
        #{self}.set(serial_obj: serial_obj, channel: #{self}.new)
        #{self}.authors
      "
    end
  end
end
