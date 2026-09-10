# frozen_string_literal: true

require 'meshtastic/module_config_pb'

module Meshtastic
  class ModuleConfig
    public_class_method def self.get(opts = {})
      Admin.send(opts.merge(get_module_config_request: opts.fetch(:module_config_type, :MQTT_CONFIG)))
    end

    public_class_method def self.set(opts = {})
      Admin.send(opts.merge(set_module_config: opts.fetch(:module_config)))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the get class method for this module.
        #{self}.get

        # Run the set class method for this module.
        #{self}.set

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
