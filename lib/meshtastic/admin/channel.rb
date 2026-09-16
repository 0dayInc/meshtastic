# frozen_string_literal: true

require 'meshtastic/channel_pb'
require 'meshtastic/apponly_pb'
require 'base64'
require 'uri'

module Meshtastic
  module Admin
    module Channel
      public_class_method def self.build_settings(opts = {})
        source = opts[:settings]
        settings = if source.is_a?(Hash)
                     Meshtastic::ChannelSettings.new(source)
                   elsif source
                     Meshtastic::ChannelSettings.decode(source.to_proto)
                   else
                     Meshtastic::ChannelSettings.new
                   end
        Meshtastic::ChannelSettings.descriptor.each do |field|
          key = field.name.to_sym
          next unless opts.key?(key)

          value = opts[key]
          value = field.subtype.msgclass.new(value) if value.is_a?(Hash) && field.subtype
          settings[field.name] = value
        end
        raise ArgumentError, 'PSK must contain 0, 1, 16, or 32 raw bytes' unless [0, 1, 16, 32].include?(settings.psk.bytesize)
        raise ArgumentError, 'channel name must be fewer than 12 bytes' unless settings.name.bytesize < 12

        settings
      end

      public_class_method def self.build(opts = {})
        channel = opts[:channel] ? Meshtastic::Channel.decode(opts[:channel].to_proto) : Meshtastic::Channel.new
        index = opts.fetch(:index, channel.index)
        raise ArgumentError, 'index must be an integer from 0 through 7' unless index.is_a?(Integer) && (0..7).cover?(index)

        channel.index = index
        channel.role = opts[:role] if opts[:role]
        raise ArgumentError, 'role must be PRIMARY, SECONDARY, or DISABLED' unless %i[PRIMARY SECONDARY DISABLED].include?(channel.role)

        channel.settings = build_settings(opts.merge(settings: opts.fetch(:settings, channel.settings)))
        channel
      end

      public_class_method def self.get(opts = {})
        index = opts[:index]
        index = 0 if index.nil?
        Admin.get_channel(opts.merge(index: index))
      end

      public_class_method def self.set(opts = {})
        legacy = opts.keys & %i[serial_obj bluetooth_obj tcp_obj mqtt_obj]
        raise ArgumentError, "#{legacy.join(', ')} are unsupported; use transport_obj" unless legacy.empty?

        channel = build(opts.merge({}))
        builder_keys = Meshtastic::ChannelSettings.descriptor.map { |field| field.name.to_sym } + %i[channel index role settings]
        merged = opts.except(*builder_keys).merge(channel_settings: channel)
        Admin.set_channel(merged)
      end

      public_class_method def self.export_url(opts = {})
        channels = opts.fetch(:channels)
        raise ArgumentError, 'exactly one primary channel is required' unless channels.one? { |channel| channel.role == :PRIMARY }

        enabled = channels.select { |channel| channel.role == :PRIMARY || (opts[:include_all] != false && channel.role == :SECONDARY) }
        raise ArgumentError, 'at most eight enabled channels can be shared' if enabled.length > 8

        enabled = enabled.sort_by { |channel| [channel.role == :PRIMARY ? 0 : 1, channel.index] }
        settings = enabled.map { |channel| build_settings(settings: channel.settings) }
        channel_set = Meshtastic::ChannelSet.new(settings: settings, lora_config: opts[:lora_config])
        "https://meshtastic.org/e/##{Base64.urlsafe_encode64(channel_set.to_proto, padding: false)}"
      end

      public_class_method def self.import_url(opts = {})
        uri = URI.parse(opts.fetch(:url))
        valid = uri.scheme == 'https' && uri.host == 'meshtastic.org' && %w[/e/ /d/].include?(uri.path)
        valid &&= uri.userinfo.nil? && uri.port == 443 && uri.fragment&.match?(/\A[A-Za-z0-9_-]+={0,2}\z/)
        raise ArgumentError, 'invalid channel URL' unless valid

        channel_set = Meshtastic::ChannelSet.decode(Base64.urlsafe_decode64(uri.fragment))
        raise ArgumentError, 'invalid channel URL' unless (1..8).cover?(channel_set.settings.length)

        channel_set
      rescue URI::InvalidURIError, Google::Protobuf::ParseError, ArgumentError, TypeError
        raise ArgumentError, 'invalid channel URL'
      end

      public_class_method def self.apply_url(opts = {})
        channel_set = import_url(url: opts[:url])
        raise ArgumentError, 'add-only or query URL application is not supported; import offline and select slots explicitly' if URI.parse(opts[:url]).query

        transport = opts.except(:url)
        channels = channel_set.settings.each_with_index.map do |settings, index|
          build(index: index, role: index.zero? ? :PRIMARY : :SECONDARY, settings: settings)
        end
        results = channels.map { |channel| set(transport.merge(channel: channel)) }
        results << Config.set_lora(transport.merge(lora: channel_set.lora_config)) if channel_set.lora_config
        results
      end

      public_class_method def self.authors
        "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
      end

      public_class_method def self.help
        puts "USAGE:
          # Build ChannelSettings for a mesh channel.
          #{self}.build_settings(
            settings: 'optional - ChannelSettings protobuf or Hash copied before overlay',
            name: 'optional - channel name shorter than twelve UTF-8 bytes',
            psk: 'optional - raw PSK of zero, one, sixteen, or thirty-two bytes',
            channel_num: 'optional - deprecated channel number; prefer Config LoRa channel_num',
            id: 'optional - channel hash id',
            uplink_enabled: 'optional - whether MQTT uplink is enabled',
            downlink_enabled: 'optional - whether MQTT downlink is enabled',
            module_settings: 'optional - ModuleSettings protobuf or field Hash for precision and mute',
            use_aead: 'optional - whether AEAD crypto is enabled'
          )

          # Build a Channel protobuf with index, role, and settings.
          #{self}.build(
            channel: 'optional - existing Channel protobuf copied before overlay',
            index: 'optional - integer channel slot zero through seven',
            role: 'optional - :PRIMARY, :SECONDARY, or :DISABLED',
            settings: 'optional - ChannelSettings protobuf or field Hash to attach'
          )

          # Request a channel slot from the node.
          #{self}.get(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client',
            index: 'optional - zero-based channel slot; Admin adds one on wire (default: 0)'
          )

          # Write a channel slot on the node.
          #{self}.set(
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client',
            channel: 'optional - Channel protobuf to write',
            index: 'optional - channel slot index when building a channel',
            role: 'optional - :PRIMARY, :SECONDARY, or :DISABLED',
            settings: 'optional - ChannelSettings protobuf or field Hash to attach'
          )

          # Export enabled channels to a sharing URL.
          #{self}.export_url(
            channels: 'required - array of Channel protobufs with one primary',
            include_all: 'optional - include secondary channels unless false',
            lora_config: 'optional - LoRaConfig protobuf included in the URL'
          )

          # Decode a sharing URL without writing hardware.
          #{self}.import_url(url: 'required - Meshtastic e or d channel URL')

          # Write URL channels and optional LoRa configuration.
          #{self}.apply_url(
            url: 'required - Meshtastic channel URL replacing slots from zero',
            transport_obj: 'required - connected Serial, Bluetooth, TCP handle or MQTT client'
          )

          # Print the AUTHOR(S) string for this module.
          #{self}.authors
        "
      end
    end
  end
end
