# frozen_string_literal: true

require 'base64'
require 'geocoder'
require 'json'
require 'mqtt'
require 'openssl'
require 'securerandom'

# Avoiding Namespace Collisions
MQTTClient = MQTT::Client

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  module MQTT
    # Supported Method Parameters::
    # mqtt_obj = Meshtastic::MQTT.connect(
    #   host: 'optional - mqtt host (default: mqtt.meshtastic.org)',
    #   port: 'optional - mqtt port (defaults: 1883)',
    #   tls: 'optional - use TLS (default: false)',
    #   username: 'optional - mqtt username (default: meshdev)',
    #   password: 'optional - (default: large4cats)',
    #   client_id: 'optional - client ID (default: random 4-byte hex string)',
    #   keep_alive: 'optional - keep alive interval (default: 15)',
    #   ack_timeout: 'optional - acknowledgement timeout (default: 30)'
    # )

    public_class_method def self.connect(opts = {})
      # Publicly available MQTT server / credentials by default
      host = opts[:host] ||= 'mqtt.meshtastic.org'
      port = opts[:port] ||= 1883
      tls = true if opts[:tls]
      tls = false unless opts[:tls]
      username = opts[:username] ||= 'meshdev'
      password = opts[:password] ||= 'large4cats'
      client_id = opts[:client_id] ||= SecureRandom.random_bytes(4).unpack1('H*').to_s
      client_id = format("%0.8x", client_id) if client_id.is_a?(Integer)
      client_id = client_id.delete('!') if client_id.include?('!')
      keep_alive = opts[:keep_alive] ||= 15
      ack_timeout = opts[:ack_timeout] ||= 30

      mqtt_obj = MQTTClient.connect(
        host: host,
        port: port,
        ssl: tls,
        username: username,
        password: password,
        client_id: client_id
      )

      mqtt_obj.keep_alive = keep_alive
      mqtt_obj.ack_timeout = ack_timeout

      mqtt_obj
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::MQTT.subscribe(
    #   mqtt_obj: 'required - mqtt_obj returned from #connect method'
    #   root_topic: 'optional - root topic (default: msh)',
    #   region: 'optional - region e.g. 'US/VA', etc (default: US)',
    #   topic: 'optional - channel ID path e.g. "2/stat/#" (default: "2/e/LongFast/#")',
    #   psks: 'optional - hash of :channel_id => psk key value pairs (default: { LongFast: "AQ==" })',
    #   qos: 'optional - quality of service (default: 0)',
    #   exclude: 'optional - comma-delimited string(s) to exclude in message (default: nil)',
    #   include: 'optional - comma-delimited string(s) to include on in message (default: nil)',
    #   gps_metadata: 'optional - include GPS metadata in output (default: false)',
    #   include_raw: 'optional - include raw packet data in output (default: false)'
    # )

    public_class_method def self.subscribe(opts = {})
      mqtt_obj = opts[:mqtt_obj]
      root_topic = opts[:root_topic] ||= 'msh'
      region = opts[:region] ||= 'US'
      topic = opts[:topic] ||= '2/e/LongFast/#'
      # TODO: Support Array of PSKs and attempt each until decrypted

      public_psk = '1PG7OiApB1nwvP+rz05pAQ=='
      psks = opts[:psks] ||= { LongFast: public_psk }
      raise 'ERROR: psks parameter must be a hash of :channel_id => psk key value pairs' unless psks.is_a?(Hash)

      psks[:LongFast] = public_psk if psks[:LongFast] == 'AQ=='
      mui = Meshtastic::MeshInterface.new
      psks = mui.get_cipher_keys(psks: psks)

      qos = opts[:qos] ||= 0
      json = opts[:json] ||= false
      exclude = opts[:exclude]
      include = opts[:include]
      gps_metadata = opts[:gps_metadata] ||= false
      include_raw = opts[:include_raw] ||= false

      # NOTE: Use MQTT Explorer for topic discovery
      full_topic = "#{root_topic}/#{region}/#{topic}"
      full_topic = "#{root_topic}/#{region}" if region == '#'
      puts "Subscribing to: #{full_topic}"
      mqtt_obj.subscribe(full_topic, qos)

      # MQTT::ProtocolException: No Ping Response received for 23 seconds (MQTT::ProtocolException)

      include_arr = include.to_s.split(',').map(&:strip)
      exclude_arr = exclude.to_s.split(',').map(&:strip)
      mqtt_obj.get_packet do |packet_bytes|
        raw_packet = packet_bytes.to_s if include_raw
        raw_topic = packet_bytes.topic ||= ''
        raw_payload = packet_bytes.payload ||= ''

        begin
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

          if message.keys.include?(:public_key)
            raw_public_key = message[:public_key]
            message[:public_key] = Base64.strict_encode64(raw_public_key)
          end

          # If encrypted_message is not nil, then decrypt
          # the message prior to decoding.
          encrypted_message = message[:encrypted]
          if encrypted_message.to_s.length.positive? &&
             message[:topic]

            # if message[:pki_encrypted]
            #   # TODO: Display Decrypted PKI Message
            #   public_key = message[:public_key]
            #   dec_public_key = Base64.strict_decode64(public_key)
            # else
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
            # end
            message[:decoded] = Meshtastic::Data.decode(decrypted).to_h
            message[:encrypted] = :decrypted
          end

          if message[:decoded]
            # payload = Meshtastic::Data.decode(message[:decoded][:payload]).to_h
            payload = message[:decoded][:payload]
            msg_type = message[:decoded][:portnum]
            mui = Meshtastic::MeshInterface.new
            message[:decoded][:payload] = mui.decode_payload(
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
          # include_arr = [message[:id].to_s] if include_arr.empty?
          if message.is_a?(Hash)
            flat_message = message.values.join(' ')

            disp = false
            # disp = true if exclude_arr.none? { |exclude| flat_message.include?(exclude) } && (
            #                  include_arr.first == message[:id] ||
            #                  include_arr.all? { |include| flat_message.include?(include) }
            #                )

            disp = true if exclude_arr.none? { |exclude| flat_message.include?(exclude) } &&
                           include_arr.all? { |include| flat_message.include?(include) }

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
    # Meshtastic::MQTT.send_text(
    #   mqtt_obj: 'required - mqtt_obj returned from #connect method',
    #   from: 'required - From ID (String or Integer) (Default: "!00000b0b")',
    #   to: 'optional - Destination ID (Default: "!ffffffff")',
    #   root_topic: 'optional - root topic (default: msh)',
    #   region: 'optional - region e.g. "US/VA", etc (default: US)',
    #   topic: 'optional - topic to publish to (default: "2/e/LongFast/#")',
    #   channel: 'optional - channel (Default: 6)',
    #   text: 'optional - Text Message (Default: SYN)',
    #   want_ack: 'optional - Want Acknowledgement (Default: false)',
    #   want_response: 'optional - Want Response (Default: false)',
    #   hop_limit: 'optional - Hop Limit (Default: 3)',
    #   on_response: 'optional - Callback on Response',
    #   psks: 'optional - hash of :channel_id => psk key value pairs (default: { LongFast: "AQ==" })'
    # )
    public_class_method def self.send_text(opts = {})
      mqtt_obj = opts[:mqtt_obj]
      opts[:from] ||= mqtt_obj.client_id
      opts[:to] ||= '!ffffffff'
      opts[:root_topic] ||= 'msh'
      opts[:region] ||= 'US'
      opts[:topic] ||= '2/e/LongFast/#'
      opts[:topic] = opts[:topic].to_s.gsub('/#', '')
      opts[:channel] ||= 6
      absolute_topic = "#{opts[:root_topic]}/#{opts[:region]}/#{opts[:topic]}/#{opts[:from]}"
      opts[:topic] = absolute_topic
      opts[:via] = :mqtt

      # TODO: Implement chunked message to deal with large messages
      text = opts[:text].to_s
      max_bytes = 231
      mui = Meshtastic::MeshInterface.new

      if text.bytesize > max_bytes
        total_chunks = (text.bytesize.to_f / max_bytes).ceil
        total_chunks.times do |i|
          chunk_num = i + 1
          chunk_prefix = " (#{chunk_num} of #{total_chunks})"
          chunk_prefix_len = chunk_prefix.bytesize
          start_index = i * (max_bytes - chunk_prefix_len)
          end_index = (start_index + (max_bytes - chunk_prefix_len)) - 1
          chunk = "#{chunk_prefix} #{text.byteslice(start_index..end_index)}"
          # This addresses a weird bug in the protocal if the first byte
          # is an h or H followed by a single byte, which returns
          # {} or {bitfiled: INT}
          opts[:text] = chunk
          protobuf_chunk = mui.send_text(opts)
          mqtt_obj.publish(absolute_topic, protobuf_chunk)
          sleep 0.3
        end
      else
        opts[:text] = " #{text}"
        protobuf_text = mui.send_text(opts)
        mqtt_obj.publish(absolute_topic, protobuf_text)
      end
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
          tls: 'optional - use TLS (default: false)',
          username: 'optional - mqtt username (default: meshdev)',
          password: 'optional - (default: large4cats)',
          client_id: 'optional - client ID (default: random 4-byte hex string)',
          keep_alive: 'optional - keep alive interval (default: 15)',
          ack_timeout: 'optional - acknowledgement timeout (default: 30)'
        )

        #{self}.subscribe(
          mqtt_obj: 'required - mqtt_obj object returned from #connect method',
          root_topic: 'optional - root topic (default: msh)',
          region: 'optional - region e.g. 'US/VA', etc (default: US)',
          topic: 'optional - channel ID path e.g. '2/stat/#' (default: '2/e/LongFast/#')',
          psks: 'optional - hash of :channel_id => psk key value pairs (default: { LongFast: 'AQ==' })',
          qos: 'optional - quality of service (default: 0)',
          json: 'optional - JSON output (default: false)',
          exclude: 'optional - comma-delimited string(s) to exclude in message (default: nil)',
          include: 'optional - comma-delimited string(s) to include on in message (default: nil)',
          gps_metadata: 'optional - include GPS metadata in output (default: false)'
        )

        #{self}.send_text(
          mqtt_obj: 'required - mqtt_obj returned from #connect method',
          from: 'required - From ID (String or Integer) (Default: \"!00000b0b\")',
          to: 'optional - Destination ID (Default: \"!ffffffff\")',
          root_topic: 'optional - root topic (default: msh)',
          region: 'optional - region e.g. 'US/VA', etc (default: US)',
          topic: 'optional - topic to publish to (default: '2/e/LongFast/#')',
          channel: 'optional - channel (Default: 6)',
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
