# frozen_string_literal: true

require 'meshtastic/module_config_pb'

module Meshtastic
  class ModuleConfig
    def self.get(opts = {})
      Admin.send(opts.merge(get_module_config_request: opts.fetch(:module_config_type, :MQTT_CONFIG)))
    end

    def self.set(opts = {})
      Admin.send(opts.merge(set_module_config: opts.fetch(:module_config)))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.get(serial_obj: serial_obj, module_config_type: :MQTT_CONFIG)
        #{self}.set(serial_obj: serial_obj, module_config: #{self}.new)
        #{self}.authors
      "
    end
  end
end
