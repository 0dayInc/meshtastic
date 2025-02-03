# frozen_string_literal: true

require 'base64'
require 'geocoder'
require 'json'
require 'mqtt'
require 'openssl'
require 'securerandom'
require 'tty-prompt'

# Avoiding Namespace Collisions
MQTTClient = MQTT::Client

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  module MQTT
    # Supported Method Parameters::
    # mqtt_obj = Meshtastic::MQQT.connect(
    #   host: 'optional - mqtt host (default: mqtt.meshtastic.org)',
    #   port: 'optional - mqtt port (defaults: 1883)',
    #   username: 'optional - mqtt username (default: meshdev)',
    #   password: 'optional - (default: large4cats)',
    #   client_id: 'optional - client ID (default: random 4-byte hex string)'
    # )

    public_class_method def self.connect(opts = {})
      # Publicly available MQTT server / credentials by default
      host = opts[:host] ||= 'mqtt.meshtastic.org'
      port = opts[:port] ||= 1883
      username = opts[:username] ||= 'meshdev'
      password = opts[:password] ||= 'large4cats'
      client_id = opts[:client_id] ||= SecureRandom.random_bytes(4).unpack1('H*').to_s
      client_id = client_id.delete('!') if client_id.include?('!')

      MQTTClient.connect(
        host: host,
        port: port,
        username: username,
        password: password,
        client_id: client_id
      )
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::MQQT.subscribe(
    #   mqtt_obj: 'required - mqtt_obj returned from #connect method'
    #   root_topic: 'optional - root topic (default: msh)',
    #   region: 'optional - region e.g. 'US/VA', etc (default: US)',
    #   channel: 'optional - channel name e.g. "2/stat/#" (default: "2/e/LongFast/#")',
    #   psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: "AQ==" })',
    #   qos: 'optional - quality of service (default: 0)',
    #   filter: 'optional - comma-delimited string(s) to filter on in message (default: nil)',
    #   gps_metadata: 'optional - include GPS metadata in output (default: false)',
    #   include_raw: 'optional - include raw packet data in output (default: false)'
    # )

    public_class_method def self.subscribe(opts = {})
      mqtt_obj = opts[:mqtt_obj]
      root_topic = opts[:root_topic] ||= 'msh'
      region = opts[:region] ||= 'US'
      channel = opts[:channel] ||= '2/e/LongFast/#'
      # TODO: Support Array of PSKs and attempt each until decrypted

      public_psk = '1PG7OiApB1nwvP+rz05pAQ=='
      psks = opts[:psks] ||= { LongFast: public_psk }
      raise 'ERROR: psks parameter must be a hash of :channel => psk key value pairs' unless psks.is_a?(Hash)

      psks[:LongFast] = public_psk if psks[:LongFast] == 'AQ=='
      psks = Meshtastic.get_cipher_keys(psks: psks)

      qos = opts[:qos] ||= 0
      json = opts[:json] ||= false
      filter = opts[:filter]
      gps_metadata = opts[:gps_metadata] ||= false
      include_raw = opts[:include_raw] ||= false

      # NOTE: Use MQTT Explorer for topic discovery
      full_topic = "#{root_topic}/#{region}/#{channel}"
      full_topic = "#{root_topic}/#{region}" if region == '#'
      puts "Subscribing to: #{full_topic}"
      mqtt_obj.subscribe(full_topic, qos)

      filter_arr = filter.to_s.split(',').map(&:strip)
      mqtt_obj.get_packet do |packet_bytes|
        raw_packet = packet_bytes.to_s if include_raw
        raw_topic = packet_bytes.topic ||= ''
        raw_payload = packet_bytes.payload ||= ''

        begin
          disp = false
          decoded_payload_hash = {}
          message = {}
          stdout_message = ''

          if json
            decoded_payload_hash = JSON.parse(raw_payload, symbolize_names: true)
          else
            decoded_payload = Meshtastic::ServiceEnvelope.decode(raw_payload)
            decoded_payload_hash = decoded_payload.to_h
          end

          next unless decoded_payload_hash[:packet].is_a?(Hash)

          message = decoded_payload_hash[:packet] if decoded_payload_hash.keys.include?(:packet)
          message[:topic] = raw_topic
          message[:node_id_from] = "!#{message[:from].to_i.to_s(16)}"
          message[:node_id_to] = "!#{message[:to].to_i.to_s(16)}"
          if message.keys.include?(:rx_time)
            rx_time_int = message[:rx_time]
            if rx_time_int.is_a?(Integer)
              rx_time_utc = Time.at(rx_time_int).utc.to_s
              message[:rx_time_utc] = rx_time_utc
            end
          end

          # If encrypted_message is not nil, then decrypt
          # the message prior to decoding.
          encrypted_message = message[:encrypted]
          if encrypted_message.to_s.length.positive? &&
             message[:topic]

            packet_id = message[:id]
            packet_from = message[:from]

            nonce_packet_id = [packet_id].pack('V').ljust(8, "\x00")
            nonce_from_node = [packet_from].pack('V').ljust(8, "\x00")
            nonce = "#{nonce_packet_id}#{nonce_from_node}"

            psk = psks[:LongFast]
            target_channel = message[:topic].split('/')[-2].to_sym
            psk = psks[target_channel] if psks.keys.include?(target_channel)
            dec_psk = Base64.strict_decode64(psk)

            cipher = OpenSSL::Cipher.new('AES-128-CTR')
            cipher = OpenSSL::Cipher.new('AES-256-CTR') if dec_psk.length == 32
            cipher.decrypt
            cipher.key = dec_psk
            cipher.iv = nonce

            decrypted = cipher.update(encrypted_message) + cipher.final
            message[:decoded] = Meshtastic::Data.decode(decrypted).to_h
            message[:encrypted] = :decrypted
          end

          if message[:decoded]
            # payload = Meshtastic::Data.decode(message[:decoded][:payload]).to_h
            payload = message[:decoded][:payload]
            msg_type = message[:decoded][:portnum]
            message[:decoded][:payload] = Meshtastic.decode_payload(
              payload: payload,
              msg_type: msg_type,
              gps_metadata: gps_metadata
            )
          end

          message[:raw_packet] = raw_packet if include_raw
          decoded_payload_hash[:packet] = message
          unless block_given?
            message[:stdout] = 'pretty'
            stdout_message = JSON.pretty_generate(decoded_payload_hash)
          end
        rescue Encoding::CompatibilityError,
               Google::Protobuf::ParseError,
               JSON::GeneratorError,
               ArgumentError => e

          unless e.is_a?(Encoding::CompatibilityError)
            message[:decrypted] = e.message if e.message.include?('key must be')
            message[:decrypted] = 'unable to decrypt - psk?' if e.message.include?('occurred during parsing')
            decoded_payload_hash[:packet] = message
            unless block_given?
              puts "WARNING: #{e.inspect} - MSG IS >>>"
              # puts e.backtrace
              message[:stdout] = 'inspect'
              stdout_message = decoded_payload_hash.inspect
            end
          end

          next
        ensure
          filter_arr = [message[:id].to_s] if filter.nil?
          if message.is_a?(Hash)
            flat_message = message.values.join(' ')

            disp = true if filter_arr.first == message[:id] ||
                           filter_arr.all? { |filter| flat_message.include?(filter) }

            if disp
              if block_given?
                yield decoded_payload_hash
              else
                puts "\n"
                puts '-' * 80
                puts 'MSG:'
                puts stdout_message
                puts '-' * 80
                puts "\n\n\n"
              end
              # else
              # print '.'
            end
          end
        end
      end
    rescue Interrupt
      puts "\nCTRL+C detected. Exiting..."
    rescue StandardError => e
      raise e
    ensure
      mqtt_obj.disconnect if mqtt_obj
    end

    # Supported Method Parameters::
    # Meshtastic.send_text(
    #   mqtt_obj: 'required - mqtt_obj returned from #connect method',
    #   from: ' required - From ID (String or Integer)',
    #   to: 'optional - Destination ID (Default: 0xFFFFFFFF)',
    #   topic: 'optional - topic to publish to (default: "msh/US/2/e/LongFast/1")',
    #   channel: 'optional - channel ID (Default: 6)',
    #   text: 'optional - Text Message (Default: SYN)',
    #   want_ack: 'optional - Want Acknowledgement (Default: false)',
    #   want_response: 'optional - Want Response (Default: false)',
    #   hop_limit: 'optional - Hop Limit (Default: 3)',
    #   on_response: 'optional - Callback on Response',
    #   psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: "AQ==" })'
    # )
    public_class_method def self.send_text(opts = {})
      mqtt_obj = opts[:mqtt_obj]
      topic = opts[:topic] ||= 'msh/US/2/e/LongFast/#'
      opts[:via] = :mqtt

      # TODO: Implement chunked message to deal with large messages
      protobuf_text = Meshtastic.send_text(opts)

      mqtt_obj.publish(topic, protobuf_text)
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # mqtt_obj = Meshtastic.disconnect(
    #   mqtt_obj: 'required - mqtt_obj returned from #connect method'
    # )
    public_class_method def self.disconnect(opts = {})
      mqtt_obj = opts[:mqtt_obj]

      mqtt_obj.disconnect if mqtt_obj
      nil
    rescue StandardError => e
      raise e
    end

    # Author(s):: 0day Inc. <support@0dayinc.com>

    public_class_method def self.authors
      "AUTHOR(S):
        0day Inc. <support@0dayinc.com>
      "
    end

    # Display Usage for this Module

    public_class_method def self.help
      puts "USAGE:
        mqtt_obj = #{self}.connect(
          host: 'optional - mqtt host (default: mqtt.meshtastic.org)',
          port: 'optional - mqtt port (defaults: 1883)',
          username: 'optional - mqtt username (default: meshdev)',
          password: 'optional - (default: large4cats)',
          client_id: 'optional - client ID (default: random 4-byte hex string)'
        )

        #{self}.subscribe(
          mqtt_obj: 'required - mqtt_obj object returned from #connect method',
          root_topic: 'optional - root topic (default: msh)',
          region: 'optional - region e.g. 'US/VA', etc (default: US)',
          channel: 'optional - channel name e.g. '2/stat/#' (default: '2/e/LongFast/#')',
          psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: 'AQ==' })',
          qos: 'optional - quality of service (default: 0)',
          json: 'optional - JSON output (default: false)',
          filter: 'optional - comma-delimited string(s) to filter on in message (default: nil)',
          gps_metadata: 'optional - include GPS metadata in output (default: false)'
        )

        #{self}.send_text(
          mqtt_obj: 'required - mqtt_obj returned from #connect method',
          from: ' required - From ID (String or Integer)',
          to: 'optional - Destination ID (Default: 0xFFFFFFFF)',
          topic: 'optional - topic to publish to (default: 'msh/US/2/e/LongFast/1')',
          channel: 'optional - channel ID (Default: 6)',
          text: 'optional - Text Message (Default: SYN)',
          want_ack: 'optional - Want Acknowledgement (Default: false)',
          want_response: 'optional - Want Response (Default: false)',
          hop_limit: 'optional - Hop Limit (Default: 3)',
          on_response: 'optional - Callback on Response',
          psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: 'AQ==' })'
        )

        mqtt_obj = #{self}.disconnect(
          mqtt_obj: 'required - mqtt_obj object returned from #connect method'
        )

        #{self}.authors
      "
    end
  end
end
