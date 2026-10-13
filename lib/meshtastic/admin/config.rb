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

      public_class_method def self.set_packet_signature_policy(opts = {})
        policy = opts.fetch(:policy)
        enum = Meshtastic::Config::SecurityConfig::PacketSignaturePolicy
        valid = policy.is_a?(Symbol) ? enum.resolve(policy) : (policy.is_a?(Integer) && enum.lookup(policy))
        raise ArgumentError, 'policy must be a known PacketSignaturePolicy symbol or integer' unless valid

        section = Meshtastic::Config::SecurityConfig.new(packet_signature_policy: policy)
        Admin::Validation.validate(message: Meshtastic::AdminMessage.new(set_config: Meshtastic::Config.new(security: section)))
        update_field(opts.except(:policy).merge(section: :security, config_type: :SECURITY_CONFIG, field: :packet_signature_policy,
                                                value: section.packet_signature_policy))
      end

      public_class_method def self.set_receive_only(opts = {})
        enabled = opts.fetch(:enabled)
        raise ArgumentError, 'enabled must be true or false' unless [true, false].include?(enabled)
        raise ArgumentError, 'receive-only requires a local radio connection' if Admin.transport_type(opts) == :mqtt

        connection = opts.fetch(:transport_obj)
        target = opts.fetch(:to, connection[:my_node_num])
        target = target.delete_prefix('!').to_i(16) if target.is_a?(String) && target.match?(/\A![0-9a-fA-F]{8}\z/)
        raise ArgumentError, 'receive-only requires the local node for reliable readback and recovery' unless target && target == connection[:my_node_num]

        update_field(opts.except(:enabled).merge(section: :lora, config_type: :LORA_CONFIG, field: :tx_enabled, value: !enabled))
      end

      private_class_method def self.update_field(opts = {})
        section = opts.fetch(:section)
        field = opts.fetch(:field)
        value = opts.fetch(:value)
        options = opts.except(:section, :field, :value, :config_type, :wait, :request_id).merge(wait: true)
        query = options.merge(get_config_request: opts.fetch(:config_type))
        before = Admin.request(query).fetch(:value)
        raise IOError, "expected #{section} configuration readback" unless before.is_a?(Meshtastic::Config) && before.payload_variant == section

        intended = Meshtastic::Config.decode(before.to_proto)
        intended.public_send(section).public_send("#{field}=", value)
        acknowledgment = Admin.request(options.merge(set_config: intended))
        readback = Admin.request(query)
        actual = readback.fetch(:value)
        matched = actual.is_a?(Meshtastic::Config) && actual.payload_variant == section && actual.public_send(section).public_send(field) == value
        { acknowledgment: acknowledgment, readback: readback, matched: matched, reboot_requested: false }
      end

      public_class_method def self.authors
        "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
      end

      public_class_method def self.help
        puts "USAGE:
          # Request a radio Config section by ConfigType.
          #{self}.get(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client',
            config_type: 'optional - :DEVICE_CONFIG or another ConfigType (default: :DEVICE_CONFIG)'
          )

          # Write a Config protobuf to the node.
          #{self}.set(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client',
            config: 'required - Config protobuf with exactly one selected section; empty outer messages and unknown enum values are rejected; device_ui uses dedicated store operation'
          )

          # Request DEVICE_CONFIG from the node.
          #{self}.get_device(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Request POSITION_CONFIG from the node.
          #{self}.get_position(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Request POWER_CONFIG from the node.
          #{self}.get_power(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Request NETWORK_CONFIG from the node.
          #{self}.get_network(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Request DISPLAY_CONFIG from the node.
          #{self}.get_display(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Request LORA_CONFIG from the node.
          #{self}.get_lora(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Request BLUETOOTH_CONFIG from the node.
          #{self}.get_bluetooth(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Request SECURITY_CONFIG from the node.
          #{self}.get_security(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Request SESSIONKEY_CONFIG from the node.
          #{self}.get_sessionkey(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Request DeviceUIConfig using dedicated firmware operation.
          #{self}.get_device_ui(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Write DeviceConfig wrapped in a Config protobuf.
          #{self}.set_device(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client',
            device: 'required - DeviceConfig protobuf or complete section field Hash'
          )

          # Write LoRaConfig wrapped in a Config protobuf.
          #{self}.set_lora(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client',
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

          # Change signature policy preserving other security fields with fresh readback.
          #{self}.set_packet_signature_policy(
            transport_obj: 'required - connected radio handle with receive queue; MQTT unsupported',
            policy: 'required - PACKET_SIGNATURE_POLICY_COMPATIBLE, BALANCED or STRICT enum symbol with full prefix, or known integer',
            to: 'optional - target node, defaults to connected radio; accepts shared Admin request options',
            timeout: 'optional - per-request positive deadline seconds; default ten'
          )

          # Set local LoRa transmit enablement with fresh readback.
          #{self}.set_receive_only(
            transport_obj: 'required - local connected radio with receive queue; remote targets and MQTT rejected',
            enabled: 'required - true disables LoRa transmission, false enables it; preserves other LoRa fields',
            to: 'optional - must equal the connected local node number',
            timeout: 'optional - per-request positive deadline seconds; default ten'
          )
          # Helpers return acknowledgment, readback, matched and reboot_requested false.
          # They do not request reboot; firmware may itself reboot/disconnect after settings changes.
          # Timeout propagates without replay; reconnect and read back before retrying mutations.

          # Print the AUTHOR(S) string for this module.
          #{self}.authors
        "
      end
    end
  end
end
