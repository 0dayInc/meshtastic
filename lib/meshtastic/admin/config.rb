# frozen_string_literal: true

require 'meshtastic/config_pb'

module Meshtastic
  module Admin
    module Config
      public_class_method def self.get(opts = {})
        Admin.get_config(opts.merge(config_type: opts[:config_type] || :DEVICE_CONFIG))
      end

      public_class_method def self.set(opts = {})
        config = opts[:config]
        raise ArgumentError, 'config must contain one Config section' unless config.is_a?(Meshtastic::Config) && config.payload_variant
        raise ArgumentError, 'sessionkey is a request-only placeholder; use get_sessionkey' if config.payload_variant == :sessionkey

        section_keys = Meshtastic::Config.descriptor.map { |field| field.name.to_sym }
        return Admin.store_ui_config(opts.except(*section_keys, :config).merge(ui_config: config.device_ui)) if config.payload_variant == :device_ui

        Admin.set_config(opts.except(*section_keys).merge(config: config))
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
        Admin.get_ui_config(opts.merge({}))
      end

      public_class_method def self.set_device(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(device: opts.fetch(:device))))
      end

      public_class_method def self.set_lora(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(lora: opts.fetch(:lora))))
      end

      public_class_method def self.set_position(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(position: opts.fetch(:position))))
      end

      public_class_method def self.set_power(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(power: opts.fetch(:power))))
      end

      public_class_method def self.set_network(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(network: opts.fetch(:network))))
      end

      public_class_method def self.set_display(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(display: opts.fetch(:display))))
      end

      public_class_method def self.set_bluetooth(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(bluetooth: opts.fetch(:bluetooth))))
      end

      public_class_method def self.set_security(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(security: opts.fetch(:security))))
      end

      public_class_method def self.set_sessionkey(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(sessionkey: opts.fetch(:sessionkey))))
      end

      public_class_method def self.set_device_ui(opts = {})
        set(opts.merge(config: Meshtastic::Config.new(device_ui: opts.fetch(:device_ui))))
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

          # Request DeviceUIConfig using dedicated firmware operation.
          #{self}.get_device_ui(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Write DeviceConfig wrapped in a Config protobuf.
          #{self}.set_device(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            device: 'required - DeviceConfig protobuf or complete section field Hash'
          )

          # Write LoRaConfig wrapped in a Config protobuf.
          #{self}.set_lora(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            lora: 'required - LoRaConfig protobuf or complete section field Hash'
          )

          # Write position configuration to node.
          #{self}.set_position(position: 'required - PositionConfig protobuf or field hash')

          # Write power configuration to node.
          #{self}.set_power(power: 'required - PowerConfig protobuf or field hash')

          # Write network configuration to node.
          #{self}.set_network(network: 'required - NetworkConfig protobuf or field hash')

          # Write display configuration to node.
          #{self}.set_display(display: 'required - DisplayConfig protobuf or field hash')

          # Write Bluetooth configuration to node.
          #{self}.set_bluetooth(bluetooth: 'required - BluetoothConfig protobuf or field hash')

          # Write security configuration to node.
          #{self}.set_security(security: 'required - SecurityConfig protobuf or field hash')

          # Reject writes to request-only session key placeholder.
          #{self}.set_sessionkey(sessionkey: 'required - placeholder only; always raises ArgumentError')

          # Write device UI configuration to node.
          #{self}.set_device_ui(device_ui: 'required - DeviceUIConfig protobuf or field hash')

          # Print the AUTHOR(S) string for this module.
          #{self}.authors
        "
      end
    end
  end
end
