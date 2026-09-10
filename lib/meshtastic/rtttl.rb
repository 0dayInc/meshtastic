# frozen_string_literal: true

require 'meshtastic/rtttl_pb'

module Meshtastic
  module RTTTL
    public_class_method def self.encode(opts = {})
      config = Meshtastic::RTTTLConfig.new
      config.ringtone = opts.fetch(:ringtone, '')
      config
    end

    public_class_method def self.set(opts = {})
      Admin.send(opts.merge(set_ringtone_message: opts.fetch(:ringtone)))
    end

    public_class_method def self.get(opts = {})
      Admin.send(opts.merge(get_ringtone_request: true))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the encode class method for this module.
        #{self}.encode

        # Run the set class method for this module.
        #{self}.set

        # Run the get class method for this module.
        #{self}.get

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
