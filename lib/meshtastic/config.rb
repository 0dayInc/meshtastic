# frozen_string_literal: true

require 'meshtastic/config_pb'

module Meshtastic
  class Config
    def self.get(opts = {})
      Admin.get_config(opts)
    end

    def self.set(opts = {})
      Admin.set_config(opts.merge(config: opts.fetch(:config)))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.get(serial_obj: serial_obj, config_type: :LORA_CONFIG)
        #{self}.set(serial_obj: serial_obj, config: #{self}.new)
        #{self}.authors
      "
    end
  end
end
