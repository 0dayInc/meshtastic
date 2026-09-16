# frozen_string_literal: true

require 'meshtastic/module_config_pb'

module Meshtastic
  class ModuleConfig
    public_class_method def self.get(opts = {})
      Admin.send(admin_options(opts).merge(get_module_config_request: opts.fetch(:module_config_type, :MQTT_CONFIG)))
    end

    public_class_method def self.set(opts = {})
      Admin.send(admin_options(opts).merge(set_module_config: opts.fetch(:module_config)))
    end

    # Keep the external transport aliases out of the Admin API.
    private_class_method def self.admin_options(opts = {})
      options = opts.merge({})
      keys = %i[transport_obj serial_obj bluetooth_obj tcp_obj mqtt_obj]
      selected = keys.reject { |name| options[name].nil? }
      raise ArgumentError, 'provide exactly one transport connection' if selected.length > 1

      key = selected.first
      connection = options[key] if key
      keys.each { |name| options.delete(name) }
      options[:transport_obj] = connection if key
      options
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the get class method for this module.
        #{self}.get(transport_obj: connection, module_config_type: :MQTT_CONFIG)

        # Run the set class method for this module.
        #{self}.set(transport_obj: connection, module_config: module_config)

        # Legacy serial_obj:, bluetooth_obj:, tcp_obj:, mqtt_obj: remain accepted.
        # Supply one non-nil connection only; mixed connection options are rejected.
        # Remote setters inherit Admin automatic sessions, not persistence readback.

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
