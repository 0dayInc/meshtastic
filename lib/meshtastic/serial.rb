# frozen_string_literal: true

require 'base64'
require 'geocoder'
require 'io/wait'
require 'json'
require 'openssl'
require 'securerandom'
require 'uart'

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  module Serial
    @console_data = []
    @proto_data = []

    # Supported Method Parameters::
    # console_thread = init_console_thread(
    #   serial_conn: 'required - SerialPort.new object'
    # )

    private_class_method def self.init_console_thread(opts = {})
      serial_conn = opts[:serial_conn]

      # Spin up a serial_obj console_thread
      Thread.new do
        # serial_conn.read_timeout = -1
        serial_conn.flush

        loop do
          serial_conn.wait_readable
          # Read raw chars into @console_data,
          # convert to readable bytes if need-be
          # later.
          @console_data << serial_conn.readchar.force_encoding('UTF-8')
        end
      end
    rescue StandardError => e
      console_thread&.terminate
      serial_conn&.close
      serial_conn = nil

      raise e
    end

    # Supported Method Parameters::
    # proto_thread = init_proto_thread(
    #   serial_conn: 'required - SerialPort.new object'
    # )

    private_class_method def self.init_proto_thread(opts = {})
      serial_conn = opts[:serial_conn]

      # Spin up a serial_obj console_thread
      Thread.new do
        # serial_conn.read_timeout = -1
        serial_conn.flush
        from_radio = Meshtastic::FromRadio.new

        loop do
          serial_conn.wait_readable
          # Read raw chars into @console_data,
          # convert to readable bytes if need-be
          # later.
          @proto_data << from_radio.to_h
        end
      end
    rescue StandardError => e
      proto_thread&.terminate
      serial_conn&.close
      serial_conn = nil

      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::Serial.request(
    #   serial_obj: 'required serial_obj returned from #connect method',
    #   payload: 'required - array of bytes OR string to write to serial device (e.g. [0x00, 0x41, 0x90, 0x00] OR "ATDT+15555555\r\n"'
    # )

    public_class_method def self.request(opts = {})
      serial_obj = opts[:serial_obj]
      payload = opts[:payload]
      serial_conn = serial_obj[:serial_conn]

      byte_arr = nil
      byte_arr = payload if payload.instance_of?(Array)
      byte_arr = payload.chars if payload.instance_of?(String)
      raise "ERROR: Invalid payload type: #{payload.class}" if byte_arr.nil?

      byte_arr.each do |byte|
        serial_conn.putc(byte)
      end

      sleep(0.1)
      serial_conn.flush
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Supported Method Parameters::
    # serial_obj = Meshtastic::Serial.connect(
    #   block_dev: 'optional - serial block device path (defaults to /dev/ttyUSB0)',
    #   baud: 'optional - (defaults to 115200)',
    #   data_bits: 'optional - (defaults to 8)',
    #   stop_bits: 'optional - (defaults to 1)',
    #   parity: 'optional - :even|:mark|:odd|:space|:none (defaults to :none)'
    # )

    public_class_method def self.connect(opts = {})
      block_dev = opts[:block_dev] ||= '/dev/ttyUSB0'
      raise "Invalid block device: #{block_dev}" unless File.exist?(block_dev)

      baud = opts[:baud] ||= 115_200
      data_bits = opts[:data_bits] ||= 8
      stop_bits = opts[:stop_bits] ||= 1
      parity = opts[:parity] ||= :none

      case parity.to_s.to_sym
      when :even
        parity = 'E'
      when :odd
        parity = 'O'
      when :none
        parity = 'N'
      end
      raise "Invalid parity: #{opts[:parity]}" if parity.nil?

      mode = "#{data_bits}#{parity}#{stop_bits}"

      serial_conn = UART.open(
        block_dev,
        baud,
        mode
      )

      serial_obj = {}
      serial_obj[:serial_conn] = serial_conn
      serial_obj[:console_thread] = init_console_thread(
        serial_conn: serial_conn
      )
      serial_obj[:proto_thread] = init_proto_thread(
        serial_conn: serial_conn
      )

      # 32 bytes of start2_byte in a byte array
      start2_byte_arr = [START2].pack('C') * 32
      request(serial_obj: serial_obj, payload: start2_byte_arr)

      mui = Meshtastic::MeshInterface.new
      mui.start_config

      serial_obj
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Supported Method Parameters::
    # console_data = Meshtastic::Serial.dump_console_data

    public_class_method def self.dump_console_data
      if block_given?
        @console_data.join.split("\n").each { |data| yield data }
      else
        @console_data.join
      end
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # console_data = Meshtastic::Serial.dump_proto_data

    public_class_method def self.dump_proto_data
      if block_given?
        @proto_data.each { |proto_hash| yield proto_hash }
      else
        @proto_data
      end
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # console_data = Meshtastic::Serial.flush_data(opts = {})

    public_class_method def self.flush_data(opts = {})
      target = opts[:target]
      case target
      when :console
        @console_data.clear
      when :proto
        @proto_data.clear
      else
        raise "ERROR: supported targets are :console or :proto"
      end
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # console_data = Meshtastic::Serial.monitor_console(
    #   refresh: 'optional - refresh interval (default: 3)',
    #   include: 'optional - comma-delimited string(s) to include in message (default: nil)',
    #   exclude: 'optional - comma-delimited string(s) to exclude in message (default: nil)'
    # )

    public_class_method def self.monitor_console(opts = {})
      refresh = opts[:refresh] ||= 3
      include = opts[:include]
      exclude = opts[:exclude]

      loop do
        exclude_arr = exclude.to_s.split(',').map(&:strip)
        include_arr = include.to_s.split(',').map(&:strip)

        dump_console_data do |data|
          disp = false
          disp = true if exclude_arr.none? { |exclude| data.include?(exclude) } && (
                           include_arr.empty? ||
                           include_arr.all? { |include| data.include?(include) }
                         )
          puts data if disp
          flush_data(target: :console)
        end
        sleep refresh
      end
    rescue Interrupt
      puts "\nCTRL+C detected. Breaking out of console mode..."
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # console_data = Meshtastic::Serial.monitor_proto(
    #   refresh: 'optional - refresh interval (default: 3)',
    #   include: 'optional - comma-delimited string(s) to include in message (default: nil)',
    #   exclude: 'optional - comma-delimited string(s) to exclude in message (default: nil)'
    # )

    public_class_method def self.monitor_proto(opts = {})
      refresh = opts[:refresh] ||= 3
      include = opts[:include]
      exclude = opts[:exclude]

      loop do
        exclude_arr = exclude.to_s.split(',').map(&:strip)
        include_arr = include.to_s.split(',').map(&:strip)

        dump_proto_data do |data|
          disp = false
          disp = true if exclude_arr.none? { |exclude| data.include?(exclude) } && (
                           include_arr.empty? ||
                           include_arr.all? { |include| data.include?(include) }
                         )
          puts data if disp
          flush_data(target: :proto)
        end
        sleep refresh
      end
    rescue Interrupt
      puts "\nCTRL+C detected. Breaking out of proto mode..."
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::Serial.subscribe(
    #   serial_obj: 'required - serial_obj returned from #connect method'
    #   root_topic: 'optional - root topic (default: msh)',
    #   region: 'optional - region e.g. 'US/VA', etc (default: US)',
    #   channel_topic: 'optional - channel ID path e.g. "2/stat/#" (default: "2/e/LongFast/#")',
    #   psks: 'optional - hash of :channel_id => psk key value pairs (default: { LongFast: "AQ==" })',
    #   qos: 'optional - quality of service (default: 0)',
    #   exclude: 'optional - comma-delimited string(s) to exclude in message (default: nil)',
    #   include: 'optional - comma-delimited string(s) to include on in message (default: nil)',
    #   gps_metadata: 'optional - include GPS metadata in output (default: false)',
    #   include_raw: 'optional - include raw packet data in output (default: false)'
    # )

    public_class_method def self.subscribe(opts = {})
      serial_obj = opts[:serial_obj]
      root_topic = opts[:root_topic] ||= 'msh'
      region = opts[:region] ||= 'US'
      channel_topic = opts[:channel_topic] ||= '2/e/LongFast/#'
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
      full_topic = "#{root_topic}/#{region}/#{channel_topic}"
      full_topic = "#{root_topic}/#{region}" if region == '#'
      puts "Subscribing to: #{full_topic}"
      serial_obj.subscribe(full_topic, qos)

      # MQTT::ProtocolException: No Ping Response received for 23 seconds (MQTT::ProtocolException)

      include_arr = include.to_s.split(',').map(&:strip)
      exclude_arr = exclude.to_s.split(',').map(&:strip)
      serial_obj.get_packet do |packet_bytes|
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
            # decoded_payload = Meshtastic::ToRadio.decode(raw_payload)
            decoded_payload = Meshtastic::FromRadio.decode(raw_payload)
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
          include_arr = [message[:id].to_s] if include_arr.empty?
          if message.is_a?(Hash)
            flat_message = message.values.join(' ')

            disp = true if exclude_arr.none? { |exclude| flat_message.include?(exclude) } && (
                             include_arr.first == message[:id] ||
                             include_arr.all? { |include| flat_message.include?(include) }
                           )

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
      serial_obj.disconnect if serial_obj
    end

    # Supported Method Parameters::
    # Meshtastic::Serial.send_text(
    #   serial_obj: 'required - serial_obj returned from #connect method',
    #   from: 'required - From ID (String or Integer) (Default: "!00000b0b")',
    #   to: 'optional - Destination ID (Default: "!ffffffff")',
    #   topic: 'optional - topic to publish to (Default: "msh/US/2/e/LongFast/1")',
    #   channel: 'optional - channel (Default: 6)',
    #   text: 'optional - Text Message (Default: SYN)',
    #   want_ack: 'optional - Want Acknowledgement (Default: false)',
    #   want_response: 'optional - Want Response (Default: false)',
    #   hop_limit: 'optional - Hop Limit (Default: 3)',
    #   on_response: 'optional - Callback on Response',
    #   psks: 'optional - hash of :channel_id => psk key value pairs (default: { LongFast: "AQ==" })'
    # )
    public_class_method def self.send_text(opts = {})
      serial_obj = opts[:serial_obj]
      topic = opts[:topic] ||= 'msh/US/2/e/LongFast/#'
      opts[:via] = :radio

      # TODO: Implement chunked message to deal with large messages
      mui = Meshtastic::MeshInterface.new
      protobuf_text = mui.send_text(opts)

      # TODO: serial equivalent of publish
      # serial_obj.publish(topic, protobuf_text)
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # serial_obj = Meshtastic.disconnect(
    #   serial_obj: 'required - serial_obj returned from #connect method'
    # )
    public_class_method def self.disconnect(opts = {})
      serial_obj = opts[:serial_obj]

      serial_obj.disconnect if serial_obj
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
        serial_obj = #{self}.connect(
          host: 'optional - mqtt host (default: mqtt.meshtastic.org)',
          port: 'optional - mqtt port (defaults: 1883)',
          tls: 'optional - use TLS (default: false)',
          username: 'optional - mqtt username (default: meshdev)',
          password: 'optional - (default: large4cats)',
          client_id: 'optional - client ID (default: random 4-byte hex string)',
          keep_alive: 'optional - keep alive interval (default: 15)',
          ack_timeout: 'optional - acknowledgement timeout (default: 30)'
        )

        #{self}.monitor_console(
          refresh: 'optional - refresh interval (default: 3)',
          include: 'optional - comma-delimited string(s) to include in message (default: nil)',
          exclude: 'optional - comma-delimited string(s) to exclude in message (default: nil)'
        )

        #{self}.monitor_proto(
          refresh: 'optional - refresh interval (default: 3)',
          include: 'optional - comma-delimited string(s) to include in message (default: nil)',
          exclude: 'optional - comma-delimited string(s) to exclude in message (default: nil)'
        )

        #{self}.subscribe(
          serial_obj: 'required - serial_obj object returned from #connect method',
          root_topic: 'optional - root topic (default: msh)',
          region: 'optional - region e.g. 'US/VA', etc (default: US)',
          channel_topic: 'optional - channel ID path e.g. '2/stat/#' (default: '2/e/LongFast/#')',
          psks: 'optional - hash of :channel_id => psk key value pairs (default: { LongFast: 'AQ==' })',
          qos: 'optional - quality of service (default: 0)',
          json: 'optional - JSON output (default: false)',
          exclude: 'optional - comma-delimited string(s) to exclude in message (default: nil)',
          include: 'optional - comma-delimited string(s) to include on in message (default: nil)',
          gps_metadata: 'optional - include GPS metadata in output (default: false)'
        )

        #{self}.send_text(
          serial_obj: 'required - serial_obj returned from #connect method',
          from: 'required - From ID (String or Integer) (Default: \"!00000b0b\")',
          to: 'optional - Destination ID (Default: \"!ffffffff\")',
          topic: 'optional - topic to publish to (default: 'msh/US/2/e/LongFast/1')',
          channel: 'optional - channel (Default: 6)',
          text: 'optional - Text Message (Default: SYN)',
          want_ack: 'optional - Want Acknowledgement (Default: false)',
          want_response: 'optional - Want Response (Default: false)',
          hop_limit: 'optional - Hop Limit (Default: 3)',
          on_response: 'optional - Callback on Response',
          psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: 'AQ==' })'
        )

        serial_obj = #{self}.disconnect(
          serial_obj: 'required - serial_obj object returned from #connect method'
        )

        #{self}.authors
      "
    end
  end
end
