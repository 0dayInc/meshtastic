# frozen_string_literal: true

require 'meshtastic/rtttl_pb'

module Meshtastic
  module RTTTL
    def self.encode(opts = {})
      config = Meshtastic::RTTTLConfig.new
      config.ringtone = opts.fetch(:ringtone, '')
      config
    end

    def self.set(opts = {})
      Admin.send(opts.merge(set_ringtone_message: opts.fetch(:ringtone)))
    end

    def self.get(opts = {})
      Admin.send(opts.merge(get_ringtone_request: true))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.set(serial_obj: serial_obj, ringtone: 'Mario:d=4,o=5,b=125:16e6')
        #{self}.get(serial_obj: serial_obj)
        #{self}.authors
      "
    end
  end
end
