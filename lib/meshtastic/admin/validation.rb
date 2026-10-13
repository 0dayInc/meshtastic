# frozen_string_literal: true

module Meshtastic
  module Admin
    # Firmware v2.8.1.8e6a88d: reject lossy writes rather than emulate clamping.
    module Validation
      public_class_method def self.validate(opts = {})
        message = opts.fetch(:message)
        message.class.descriptor.each do |field|
          value = message[field.name]
          values = field.label == :repeated ? value : [value]
          values.each do |item|
            if field.type == :enum
              known = item.is_a?(Symbol) ? field.subtype.lookup_name(item) : field.subtype.lookup_value(item)
              raise ArgumentError, "unknown enum for #{field.name}" if known.nil?
            elsif field.type == :message && item
              validate(message: item)
            end
          end
        end
        if message.is_a?(Meshtastic::Config::SecurityConfig)
          keys = [message.private_key, message.public_key] + message.admin_key.to_a
          raise ArgumentError, 'security keys must contain zero or 32 bytes; at most three admin keys' unless keys.all? { |key| [0, 32].include?(key.bytesize) } && message.admin_key.length <= 3
        end
        if message.is_a?(Meshtastic::Channel)
          raise ArgumentError, 'channel index must be from 0 through 7' unless message.index.between?(0, 7)
        elsif message.is_a?(Meshtastic::ChannelSettings)
          raise ArgumentError, 'PSK must contain 0, 1, 16, or 32 raw bytes' unless [0, 1, 16, 32].include?(message.psk.bytesize)
          raise ArgumentError, 'channel name must be fewer than 12 UTF-8 bytes without NUL' unless message.name.valid_encoding? && message.name.bytesize < 12 && !message.name.include?("\0")
        end
        if message.is_a?(Meshtastic::Config) || message.is_a?(Meshtastic::ModuleConfig)
          raise ArgumentError, 'exactly one config section is required' unless message.payload_variant
          raise ArgumentError, 'sessionkey is request-only; device_ui requires store_ui_config' if %i[sessionkey device_ui].include?(message.payload_variant)
        end
        owner(message: message) if message.is_a?(Meshtastic::User)
        ham(message: message.set_ham_mode) if message.is_a?(Meshtastic::AdminMessage) && (message.payload_variant == :set_ham_mode)
        message
      end

      private_class_method def self.owner(opts = {})
        message = opts[:message]
        name(value: message.long_name, label: 'owner long_name', limit: 24)
        name(value: message.short_name, label: 'owner short_name', limit: 4)
      end

      private_class_method def self.ham(opts = {})
        message = opts[:message]
        name(value: message.call_sign, label: 'ham call_sign', limit: 7)
        raise ArgumentError, 'ham call_sign is required' if message.call_sign.empty?

        name(value: message.long_name, label: 'ham long_name', limit: 14)
        name(value: message.short_name, label: 'ham short_name', limit: 4)
        composed = message.long_name.empty? ? message.call_sign : "#{message.call_sign}//#{message.long_name}"
        name(value: composed, label: 'ham composed owner long_name', limit: 24)
      end

      private_class_method def self.name(opts = {})
        value = opts[:value]
        valid = value.encoding == Encoding::UTF_8 && value.valid_encoding? && !value.include?("\0") && value.bytesize <= opts[:limit]
        valid &&= value.empty? || !value.match?(/\A[ \t\r\n\v\f]*\z/)
        raise ArgumentError, "#{opts[:label]} must be nonblank UTF-8 without NUL, at most #{opts[:limit]} bytes (empty means omitted)" unless valid
      end

      public_class_method def self.authors
        "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n"
      end

      public_class_method def self.help
        puts "USAGE:
          # Validate semantics without changing data or contacting hardware.
          #{self}.validate(message: 'required - protobuf message to validate against firmware v2.8.1.8e6a88d')
          # Display the module authors.
          #{self}.authors
        "
      end
    end
  end
end
