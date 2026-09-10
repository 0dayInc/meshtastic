# frozen_string_literal: true

require 'meshtastic/config_pb'

module Meshtastic
  module Admin
    module Config
      public_class_method def self.get(opts = {})
        Admin.get_config(opts.merge(config_type: opts[:config_type] || :DEVICE_CONFIG))
      end

      public_class_method def self.set(opts = {})
        Admin.set_config(opts.merge(config: opts[:config]))
      end

      public_class_method def self.get_device(opts = {})
        get(opts.merge(config_type: :DEVICE_CONFIG))
      end

      public_class_method def self.get_position(opts = {})
        get(opts.merge(config_type: :POSITION_CONFIG))
      end

      public_class_method def self.get_power(opts = {})
        get(opts.merge(config_type: :POWER_CONFIG))
      end

      public_class_method def self.get_network(opts = {})
        get(opts.merge(config_type: :NETWORK_CONFIG))
      end

      public_class_method def self.get_display(opts = {})
        get(opts.merge(config_type: :DISPLAY_CONFIG))
      end

      public_class_method def self.get_lora(opts = {})
        get(opts.merge(config_type: :LORA_CONFIG))
      end

      public_class_method def self.get_bluetooth(opts = {})
        get(opts.merge(config_type: :BLUETOOTH_CONFIG))
      end

      public_class_method def self.get_security(opts = {})
        get(opts.merge(config_type: :SECURITY_CONFIG))
      end

      public_class_method def self.get_sessionkey(opts = {})
        get(opts.merge(config_type: :SESSIONKEY_CONFIG))
      end

      public_class_method def self.get_device_ui(opts = {})
        get(opts.merge(config_type: :DEVICEUI_CONFIG))
      end

      public_class_method def self.set_device(opts = {})
        config = Meshtastic::Config.new
        config.device = opts[:device]
        set(opts.merge(config: config))
      end

      public_class_method def self.set_lora(opts = {})
        config = Meshtastic::Config.new
        config.lora = opts[:lora]
        set(opts.merge(config: config))
      end

      public_class_method def self.authors
        "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
      end

      public_class_method def self.help
        puts "USAGE:
          # Request a radio Config section by ConfigType.
          #{self}.get(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            config_type: 'optional - :DEVICE_CONFIG or another ConfigType (default: :DEVICE_CONFIG)'
          )

          # Write a Config protobuf to the node.
          #{self}.set(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            config: 'required - Meshtastic::Config protobuf to write'
          )

          # Request DEVICE_CONFIG from the node.
          #{self}.get_device(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Request POSITION_CONFIG from the node.
          #{self}.get_position(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Request POWER_CONFIG from the node.
          #{self}.get_power(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Request NETWORK_CONFIG from the node.
          #{self}.get_network(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Request DISPLAY_CONFIG from the node.
          #{self}.get_display(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Request LORA_CONFIG from the node.
          #{self}.get_lora(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Request BLUETOOTH_CONFIG from the node.
          #{self}.get_bluetooth(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Request SECURITY_CONFIG from the node.
          #{self}.get_security(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Request SESSIONKEY_CONFIG from the node.
          #{self}.get_sessionkey(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Request DEVICEUI_CONFIG from the node.
          #{self}.get_device_ui(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Write DeviceConfig wrapped in a Config protobuf.
          #{self}.set_device(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            device: 'required - Meshtastic::Config::DeviceConfig protobuf to write'
          )

          # Write LoRaConfig wrapped in a Config protobuf.
          #{self}.set_lora(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            lora: 'required - Meshtastic::Config::LoRaConfig protobuf to write'
          )

          # Print the AUTHOR(S) string for this module.
          #{self}.authors
        "
      end
    end
  end
end
