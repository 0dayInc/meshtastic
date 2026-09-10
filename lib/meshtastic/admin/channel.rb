# frozen_string_literal: true

require 'meshtastic/channel_pb'

module Meshtastic
  module Admin
    module Channel
      public_class_method def self.build_settings(opts = {})
        settings = opts[:settings] || Meshtastic::ChannelSettings.new
        settings.name = opts[:name].to_s if opts[:name]
        settings.psk = opts[:psk] if opts[:psk]
        settings.channel_num = opts[:channel_num].to_i if opts[:channel_num]
        settings.id = opts[:id].to_i if opts[:id]
        settings.uplink_enabled = opts[:uplink_enabled] unless opts[:uplink_enabled].nil?
        settings.downlink_enabled = opts[:downlink_enabled] unless opts[:downlink_enabled].nil?
        settings.module_settings = opts[:module_settings] if opts[:module_settings]
        settings.use_aead = opts[:use_aead] unless opts[:use_aead].nil?
        settings
      end

      public_class_method def self.build(opts = {})
        channel = opts[:channel] || Meshtastic::Channel.new
        channel.index = opts[:index].to_i if opts[:index]
        channel.role = opts[:role] if opts[:role]
        channel.settings = opts[:settings] || build_settings(opts.merge({}))
        channel
      end

      public_class_method def self.get(opts = {})
        index = opts[:index]
        index = 0 if index.nil?
        Admin.get_channel(opts.merge(index: index))
      end

      public_class_method def self.set(opts = {})
        channel = opts[:channel] || build(opts.merge({}))
        merged = opts.merge(channel_settings: channel)
        merged.delete(:channel)
        Admin.set_channel(merged)
      end

      public_class_method def self.authors
        "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
      end

      public_class_method def self.help
        puts "USAGE:
          # Build ChannelSettings for a mesh channel.
          #{self}.build_settings(
            settings: 'optional - existing ChannelSettings protobuf to fill',
            name: 'optional - channel name such as LongFast',
            psk: 'optional - raw PSK bytes for the channel',
            channel_num: 'optional - LoRa channel number',
            id: 'optional - channel hash id',
            uplink_enabled: 'optional - whether MQTT uplink is enabled',
            downlink_enabled: 'optional - whether MQTT downlink is enabled',
            module_settings: 'optional - ModuleSettings protobuf',
            use_aead: 'optional - whether AEAD crypto is enabled'
          )

          # Build a Channel protobuf with index, role, and settings.
          #{self}.build(
            channel: 'optional - existing Channel protobuf to fill',
            index: 'optional - channel slot index on the node',
            role: 'optional - :PRIMARY, :SECONDARY, or :DISABLED',
            settings: 'optional - ChannelSettings protobuf to attach'
          )

          # Request a channel slot from the node.
          #{self}.get(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            index: 'optional - channel slot index to request (default: 0)'
          )

          # Write a channel slot on the node.
          #{self}.set(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            channel: 'optional - Channel protobuf to write',
            index: 'optional - channel slot index when building a channel',
            role: 'optional - :PRIMARY, :SECONDARY, or :DISABLED',
            settings: 'optional - ChannelSettings protobuf to attach'
          )

          # Print the AUTHOR(S) string for this module.
          #{self}.authors
        "
      end
    end
  end
end
