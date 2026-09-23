# frozen_string_literal: true

require 'base64'
require 'geocoder'
require 'io/wait'
require 'json'
require 'openssl'
require 'securerandom'
require 'timeout'
require 'uart'

# Plugin used to interact with Meshtastic nodes over a serial (UART) link.
# Wire protocol matches the official Python client:
#   [START1=0x94][START2=0xC3][len_hi][len_lo] + protobuf(ToRadio|FromRadio)
module Meshtastic
  module Serial # rubocop:disable Metrics/ModuleLength
    @last_serial_obj = nil


    # ---- low-level IO helpers ------------------------------------------------

    private_class_method def self.clear_hupcl(opts = {})
      block_dev = opts[:block_dev]
      # Prevent device reboot on open by clearing HUPCL (same as Python pyserial path).
      return unless defined?(Termios)

      File.open(block_dev, File::RDWR | Fcntl::O_NOCTTY | Fcntl::O_NDELAY) do |f|
        attrs = Termios.tcgetattr(f)
        attrs.cflag &= ~Termios::HUPCL if defined?(Termios::HUPCL)
        Termios.tcsetattr(f, Termios::TCSAFLUSH, attrs)
      end
      sleep 0.1
    rescue StandardError
      # Best-effort — uart.open will still work without this.
      nil
    end

    # Supported Method Parameters::
    # proto_thread = init_rx_thread(
    #   serial_conn: 'required - File returned from UART.open',
    #   serial_obj:  'required - serial_obj hash being built'
    # )
    private_class_method def self.init_rx_thread(opts = {})
      serial_conn = opts[:serial_conn]
      serial_obj = opts[:serial_obj]
      debug_out = opts[:debug_out]

      serial_obj[:from_radio_queue] = Queue.new
      serial_obj[:config_queue] = Queue.new
      serial_obj[:console_data] = []
      serial_obj[:proto_data] = []
      serial_obj[:rx_mutex] = Mutex.new

      Thread.new do
        Thread.current.abort_on_exception = false
        rx_buf = +''.b
        empty = +''.b

        until serial_obj[:closing]
          begin
            next unless serial_conn.wait_readable(0.1)

            chunk = serial_conn.read_nonblock(1, exception: false)
            next if chunk == :wait_readable

            raise EOFError, 'serial device disconnected' if chunk.nil? || chunk.empty?

            c = chunk.getbyte(0)
            rx_buf << chunk
            ptr = rx_buf.bytesize - 1

            if ptr.zero?
              # looking for START1
              unless c == Meshtastic::START1
                rx_buf = empty.dup
                append_console_byte(chunk: chunk, debug_out: debug_out, serial_obj: serial_obj)
              end
            elsif ptr == 1
              # looking for START2
              unless c == Meshtastic::START2
                rx_buf = c == Meshtastic::START1 ? chunk.dup : empty.dup
              end
            elsif ptr >= (Meshtastic::HEADER_LEN - 1)
              packet_len = (rx_buf.getbyte(2) << 8) + rx_buf.getbyte(3)

              if ptr == (Meshtastic::HEADER_LEN - 1) && packet_len > Meshtastic::MAX_TO_FROM_RADIO_SIZE
                rx_buf = empty.dup
                next
              end

              if rx_buf.bytesize >= (packet_len + Meshtastic::HEADER_LEN)
                payload = rx_buf.byteslice(Meshtastic::HEADER_LEN, packet_len)
                rx_buf = empty.dup
                handle_from_radio_bytes(payload: payload, serial_obj: serial_obj)
              end
            end
          rescue IOError, SystemCallError => e
            serial_obj[:rx_error] = IOError.new("Serial receive failed: #{e.message}") unless serial_obj[:closing]
            break
          rescue StandardError => e
            warn "Meshtastic::Serial RX error: #{e.class}: #{e.message}" unless serial_obj[:closing]
            sleep 0.05
          end
        end
      ensure
        serial_obj[:from_radio_queue].close
        serial_obj[:config_queue].close
      end
    end


    private_class_method def self.append_console_byte(opts = {})
      chunk = opts[:chunk]
      debug_out = opts[:debug_out]
      serial_obj = opts[:serial_obj]
      if debug_out
        begin
          debug_out.write(chunk.force_encoding('UTF-8'))
        rescue StandardError
          debug_out.write('?')
        end
      else
        serial_obj[:rx_mutex].synchronize { serial_obj[:console_data] << chunk.force_encoding('UTF-8') }
      end
    end

    private_class_method def self.handle_from_radio_bytes(opts = {})
      payload = opts[:payload]
      serial_obj = opts[:serial_obj]
      return if payload.nil? || payload.empty?

      from_radio = Meshtastic::FromRadio.decode(payload)
      hash = from_radio.to_h

      serial_obj[:rx_mutex].synchronize { serial_obj[:proto_data] << hash }

      # Cache useful device identity on the serial_obj handle.
      if serial_obj && from_radio.my_info
        serial_obj[:my_info] = from_radio.my_info.to_h
        serial_obj[:my_node_num] = from_radio.my_info.my_node_num
      end
      serial_obj[:metadata] = from_radio.metadata.to_h if serial_obj && from_radio.metadata
      if from_radio.payload_variant == :config_complete_id && from_radio.config_complete_id == serial_obj[:config_id]
        serial_obj[:config_complete] = true
        serial_obj[:config_queue].close
      end

      if from_radio.log_record
        msg = from_radio.log_record.message.to_s
        serial_obj[:rx_mutex].synchronize { serial_obj[:console_data] << "#{msg}\n" } unless msg.empty?
      end

      serial_obj[:from_radio_queue] << from_radio
      from_radio
    rescue Google::Protobuf::ParseError => e
      warn "Meshtastic::Serial: failed to decode FromRadio (#{e.message})"
      nil
    end

    # ---- public API ----------------------------------------------------------

    # Supported Method Parameters::
    # Meshtastic::Serial.request(
    #   serial_obj: 'required serial_obj returned from #connect method',
    #   payload: 'required - array of bytes OR string to write to serial device'
    # )
    public_class_method def self.request(opts = {})
      serial_obj = opts[:serial_obj]
      serial_conn = serial_obj[:serial_conn]
      payload = opts[:payload]

      bytes =
        case payload
        when String then payload.b
        when Array  then payload.pack('C*')
        else
          raise "ERROR: Invalid payload type: #{payload.class}"
        end

      serial_obj[:tx_mutex] ||= Mutex.new
      serial_obj[:tx_mutex].synchronize do
        offset = 0
        while offset < bytes.bytesize
          count = serial_conn.write(bytes.byteslice(offset, bytes.bytesize - offset))
          raise IOError, 'serial write made no progress' unless count && count.positive?

          offset += count
        end
        serial_conn.flush
      end
      sleep 0.05
      bytes.bytesize
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::Serial.send_to_radio(
    #   serial_obj: 'required - serial_obj returned from #connect method',
    #   to_radio:   'required - Meshtastic::ToRadio OR already-serialized String'
    # )
    public_class_method def self.send_to_radio(opts = {})
      serial_obj = opts[:serial_obj]
      raise 'ERROR: serial_obj is required' unless serial_obj

      to_radio = opts[:to_radio]
      raise 'ERROR: to_radio is required' if to_radio.nil?

      body =
        case to_radio
        when String
          to_radio.b
        when Meshtastic::ToRadio
          to_radio.to_proto
        else
          raise "ERROR: to_radio must be Meshtastic::ToRadio or String, got #{to_radio.class}"
        end

      raise "ERROR: ToRadio payload too large (#{body.bytesize} > #{Meshtastic::MAX_TO_FROM_RADIO_SIZE})" if body.bytesize > Meshtastic::MAX_TO_FROM_RADIO_SIZE

      header = [
        Meshtastic::START1,
        Meshtastic::START2,
        (body.bytesize >> 8) & 0xFF,
        body.bytesize & 0xFF
      ].pack('C*')

      request(serial_obj: serial_obj, payload: header + body)
    end

    # Supported Method Parameters::
    # serial_obj = Meshtastic::Serial.connect(
    #   block_dev: 'optional - serial block device path (defaults to /dev/ttyUSB0)',
    #   baud: 'optional - (defaults to 115200)',
    #   data_bits: 'optional - (defaults to 8)',
    #   stop_bits: 'optional - (defaults to 1)',
    #   parity: 'optional - :even|:odd|:none (defaults to :none)',
    #   debug_out: 'optional - IO to receive non-protobuf debug console bytes',
    #   want_config: 'optional - request full node DB after connect (default: true)'
    # )
    public_class_method def self.connect(opts = {})
      block_dev = opts[:block_dev] ||= '/dev/ttyUSB0'
      raise "Invalid block device: #{block_dev}" unless File.exist?(block_dev)

      baud = opts[:baud] ||= 115_200
      data_bits = opts[:data_bits] ||= 8
      stop_bits = opts[:stop_bits] ||= 1
      parity = opts[:parity] ||= :none
      debug_out = opts[:debug_out]
      want_config = opts.fetch(:want_config, true)

      parity_char =
        case parity.to_s.to_sym
        when :even then 'E'
        when :odd  then 'O'
        when :none then 'N'
        else
          raise "Invalid parity: #{opts[:parity]}"
        end

      mode = "#{data_bits}#{parity_char}#{stop_bits}"

      clear_hupcl(block_dev: block_dev)

      serial_conn = UART.open(block_dev, baud, mode)

      serial_obj = {
        serial_conn: serial_conn,
        block_dev: block_dev,
        baud: baud,
        tx_mutex: Mutex.new,
        my_info: nil,
        my_node_num: nil,
        metadata: nil
      }

      serial_obj[:rx_thread] = init_rx_thread(
        serial_conn: serial_conn,
        serial_obj: serial_obj,
        debug_out: debug_out
      )
      @last_serial_obj = serial_obj

      # Wake / resync the device's framing state-machine.
      wake_up_device(serial_obj: serial_obj)

      if want_config
        mui = Meshtastic::MeshInterface.new
        to_radio_bytes = mui.start_config
        serial_obj[:config_id] = mui.config_id
        send_to_radio(serial_obj: serial_obj, to_radio: to_radio_bytes)
      end

      serial_obj
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Wait for the requested configuration without consuming application messages.
    # Raises Timeout::Error if the firmware does not complete the handshake.
    public_class_method def self.wait_for_config(opts = {})
      serial_obj = opts[:serial_obj]
      raise ArgumentError, 'serial_obj with want_config enabled is required' unless serial_obj && serial_obj[:config_id]

      serial_obj[:config_queue].pop(timeout: opts.fetch(:timeout, 10))
      raise serial_obj[:rx_error] if serial_obj[:rx_error]
      raise IOError, 'serial connection closed' if serial_obj[:closing]
      raise Timeout::Error, "No configuration response from #{serial_obj[:block_dev]}" unless serial_obj[:config_complete]

      serial_obj
    end

    # Supported Method Parameters::
    # wake_up_device(
    #   serial_obj: 'required - serial_obj returned from #connect method'
    # )
    public_class_method def self.wake_up_device(opts = {})
      serial_obj = opts[:serial_obj]
      # START2 * 32 — does not look like a valid header, forces RX state machine resync
      start2_bytes = ([Meshtastic::START2] * 32).pack('C*')
      request(serial_obj: serial_obj, payload: start2_bytes)
      sleep 0.1
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Supported Method Parameters::
    # stdout_data = Meshtastic::Serial.dump_stdout_data(
    #   type: 'required - :proto or :console'
    # )
    public_class_method def self.dump_stdout_data(opts = {})
      type = opts[:type]
      valid_types = %i[proto console]
      raise "ERROR: Invalid type: #{type}. Supported types are :proto or :console" unless valid_types.include?(type)

      serial_obj = opts[:serial_obj] || @last_serial_obj
      raise 'ERROR: call connect first' unless serial_obj

      data = serial_obj[:rx_mutex].synchronize do
        type == :proto ? serial_obj[:proto_data].dup : serial_obj[:console_data].join
      end
      return data unless block_given?

      (type == :proto ? data : data.split("\n")).each { |row| yield row } # rubocop:disable Style/ExplicitBlockArgument
      nil
    end

    # Supported Method Parameters::
    # Meshtastic::Serial.flush_data(
    #   type: 'required - :proto or :console'
    # )
    public_class_method def self.flush_data(opts = {}) # rubocop:disable Naming/PredicateMethod
      type = opts[:type]
      valid_types = %i[proto console]
      raise "ERROR: Invalid type: #{type}. Supported types are :proto or :console" unless valid_types.include?(type)

      serial_obj = opts[:serial_obj] || @last_serial_obj
      raise 'ERROR: call connect first' unless serial_obj

      serial_obj[:rx_mutex].synchronize do
        serial_obj[:console_data].clear if type == :console
        serial_obj[:proto_data].clear if type == :proto
      end
      true
    end

    # Drain the FromRadio queue without blocking (returns Array of FromRadio msgs).
    public_class_method def self.drain_from_radio(opts = {})
      max = opts[:max] ||= 256
      msgs = []
      serial_obj = opts[:serial_obj] || @last_serial_obj
      queue = serial_obj && serial_obj[:from_radio_queue]
      return msgs unless queue

      max.times do
        message = queue.pop(true)
        break unless message

        msgs << message
      rescue ThreadError
        break
      end
      msgs
    end

    # Block until a FromRadio arrives or timeout (seconds). Returns FromRadio or nil.
    public_class_method def self.recv_from_radio(opts = {})
      timeout = opts.fetch(:timeout, 5)
      serial_obj = opts[:serial_obj] || @last_serial_obj
      queue = serial_obj && serial_obj[:from_radio_queue]
      raise 'ERROR: RX queue not initialised — call connect first' unless queue

      message = if timeout.nil? || timeout.negative?
                  queue.pop
                else
                  queue.pop(timeout: timeout)
                end
      raise serial_obj[:rx_error] if message.nil? && serial_obj[:rx_error]

      message
    end

    # Supported Method Parameters::
    # Meshtastic::Serial.monitor_stdout(
    #   serial_obj: 'required - serial_obj returned from #connect method',
    #   type: 'required - :proto or :console',
    #   refresh: 'optional - refresh interval (default: 3)',
    #   include: 'optional - comma-delimited string(s) to include in message (default: nil)',
    #   exclude: 'optional - comma-delimited string(s) to exclude in message (default: nil)'
    # )
    public_class_method def self.monitor_stdout(opts = {})
      serial_obj = opts[:serial_obj]
      type = opts[:type]
      valid_types = %i[proto console]
      raise "ERROR: Invalid type: #{type}. Supported types are :proto or :console" unless valid_types.include?(type)

      refresh = opts[:refresh] ||= 3
      include = opts[:include]
      exclude = opts[:exclude]

      loop do
        exclude_arr = exclude.to_s.split(',').map(&:strip)
        include_arr = include.to_s.split(',').map(&:strip)

        dump_stdout_data(serial_obj: serial_obj, type: type) do |data|
          data_s = data.is_a?(Hash) ? data.inspect : data.to_s
          disp = exclude_arr.none? { |exc| data_s.include?(exc) } && (
            include_arr.empty? ||
            include_arr.all? { |inc| data_s.include?(inc) }
          )
          puts data_s if disp
        end
        flush_data(serial_obj: serial_obj, type: type)
        sleep refresh
      end
    rescue Interrupt
      puts "\nCTRL+C detected. Breaking out of console mode..."
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Enrich / optionally decrypt a MeshPacket hash (shared by MQTT + serial).
    private_class_method def self.enrich_packet(opts = {})
      message = opts[:message]
      psks = opts[:psks] || {}
      gps_metadata = opts[:gps_metadata] || false
      include_raw = opts[:include_raw] || false
      raw_packet = opts[:raw_packet]

      message[:node_id_from] = "!#{message[:from].to_i.to_s(16)}"
      message[:node_id_to] = "!#{message[:to].to_i.to_s(16)}"

      message[:rx_time_utc] = Time.at(message[:rx_time]).utc.to_s if message[:rx_time].is_a?(Integer)

      message[:public_key] = Base64.strict_encode64(message[:public_key]) if message[:public_key].to_s.length.positive? && !(message[:public_key].ascii_only? && message[:public_key] =~ %r{\A[A-Za-z0-9+/]+=*\z})

      Meshtastic::MeshInterface.new.decrypt_packet(message: message, psks: psks)

      if message[:decoded]
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
      message
    rescue OpenSSL::Cipher::CipherError, ArgumentError, Google::Protobuf::ParseError => e
      message[:decrypted] = e.message
      message
    end

    # Supported Method Parameters::
    # Meshtastic::Serial.subscribe(
    #   serial_obj: 'required - serial_obj returned from #connect method',
    #   psks: 'optional - hash of :channel_id => psk (default: { LongFast: "AQ==" })',
    #   exclude: 'optional - comma-delimited substrings to hide',
    #   include: 'optional - comma-delimited substrings required to display',
    #   gps_metadata: 'optional - reverse-geocode POSITION payloads (default: false)',
    #   include_raw: 'optional - include raw protobuf bytes (default: false)',
    #   timeout: 'optional - seconds to block on empty queue per iteration (default: nil = forever)'
    # )
    # Yields each decoded FromRadio hash. Without a block, pretty-prints packets.
    public_class_method def self.subscribe(opts = {})
      serial_obj = opts[:serial_obj]
      raise 'ERROR: serial_obj is required' unless serial_obj

      public_psk = '1PG7OiApB1nwvP+rz05pAQ=='
      psks = opts[:psks] ||= { LongFast: public_psk }
      raise 'ERROR: psks parameter must be a hash of :channel_id => psk key value pairs' unless psks.is_a?(Hash)

      psks[:LongFast] = public_psk if psks[:LongFast] == 'AQ=='
      mui = Meshtastic::MeshInterface.new
      psks = mui.get_cipher_keys(psks: psks)

      exclude = opts[:exclude]
      include = opts[:include]
      gps_metadata = opts[:gps_metadata] ||= false
      include_raw = opts[:include_raw] ||= false
      timeout = opts[:timeout]

      include_arr = include.to_s.split(',').map(&:strip)
      exclude_arr = exclude.to_s.split(',').map(&:strip)

      puts 'Subscribing to serial FromRadio stream...'

      loop do
        from_radio = recv_from_radio(serial_obj: serial_obj, timeout: timeout)
        break if from_radio.nil? && serial_obj[:from_radio_queue].closed?

        next if from_radio.nil?

        begin
          decoded_payload_hash = from_radio.to_h
          raw_packet = from_radio.to_proto if include_raw

          message = {}
          stdout_message = ''

          if decoded_payload_hash[:packet].is_a?(Hash)
            message = enrich_packet(
              message: decoded_payload_hash[:packet],
              psks: psks,
              gps_metadata: gps_metadata,
              include_raw: include_raw,
              raw_packet: raw_packet
            )
            decoded_payload_hash[:packet] = message
          end

          unless block_given?
            message[:stdout] = 'pretty' if message.is_a?(Hash)
            stdout_message = JSON.pretty_generate(decoded_payload_hash)
          end
        rescue Encoding::CompatibilityError,
               Google::Protobuf::ParseError,
               JSON::GeneratorError,
               ArgumentError => e
          message[:decrypted] = e.message if message.is_a?(Hash)
          decoded_payload_hash[:packet] = message if message.is_a?(Hash)
          unless block_given?
            message[:stdout] = 'inspect' if message.is_a?(Hash)
            stdout_message = decoded_payload_hash.inspect
          end
        ensure
          flat_source = decoded_payload_hash.is_a?(Hash) ? decoded_payload_hash : {}
          flat_message = flat_source.values.join(' ')
          flat_message = "#{flat_message} #{message.values.join(' ')}" if message.is_a?(Hash)

          disp = exclude_arr.none? { |exc| flat_message.include?(exc) } &&
                 include_arr.all? { |inc| flat_message.include?(inc) }

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
          end
        end
      end
    rescue Interrupt
      puts "\nCTRL+C detected. Exiting..."
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::Serial.send_text(
    #   serial_obj: 'required - serial_obj returned from #connect method',
    #   from: 'optional - From ID (Default: local my_node_num or 0 for firmware-assigned)',
    #   to: 'optional - Destination ID (Default: "!ffffffff")',
    #   channel: 'optional - channel index (Default: 0)',
    #   text: 'optional - Text Message (Default: SYN)',
    #   want_ack: 'optional - Want Acknowledgement (Default: false)',
    #   want_response: 'optional - Want Response (Default: false)',
    #   hop_limit: 'optional - Hop Limit (Default: 3)',
    #   psks: 'optional - ignored for serial (device owns channel crypto)'
    # )
    public_class_method def self.send_text(opts = {})
      serial_obj = opts[:serial_obj]
      raise 'ERROR: serial_obj is required' unless serial_obj

      opts = opts.dup
      opts[:via] = :radio
      opts[:channel] ||= 0

      opts[:from] = serial_obj[:my_node_num] || 0 if opts[:from].nil?

      # Device performs channel encryption for serial ToRadio packets.
      # Pass nil psks so MeshInterface leaves the payload in :decoded form.
      opts[:psks] = nil
      opts[:text] = opts.fetch(:text, 'SYN').to_s
      max_len = Meshtastic::Constants::DATA_PAYLOAD_LEN
      raise ArgumentError, "ERROR: Text Length > #{max_len} Bytes" if opts[:text].bytesize > max_len

      mui = Meshtastic::MeshInterface.new
      protobuf = mui.send_text(opts)
      send_to_radio(serial_obj: serial_obj, to_radio: protobuf)
    end

    # Supported Method Parameters::
    # Meshtastic::Serial.send_data(
    #   serial_obj: 'required - serial_obj returned from #connect method',
    #   ...same kwargs as MeshInterface#send_data (via forced to :radio)
    # )
    public_class_method def self.send_data(opts = {})
      serial_obj = opts[:serial_obj]
      raise 'ERROR: serial_obj is required' unless serial_obj

      opts = opts.dup
      opts[:via] = :radio
      opts[:channel] ||= 0
      opts[:psks] = nil
      opts[:from] = serial_obj[:my_node_num] || 0 if opts[:from].nil?

      mui = Meshtastic::MeshInterface.new
      protobuf = mui.send_data(opts)
      send_to_radio(serial_obj: serial_obj, to_radio: protobuf)
    end

    # Supported Method Parameters::
    # serial_obj = Meshtastic::Serial.disconnect(
    #   serial_obj: 'required - serial_obj returned from #connect method'
    # )
    public_class_method def self.disconnect(opts = {})
      serial_obj = opts[:serial_obj]
      return nil if serial_obj.nil? || serial_obj[:closing]

      serial_obj[:closing] = true
      serial_obj[:from_radio_queue]&.close
      serial_obj[:config_queue]&.close

      # Ask device to release the link (best-effort).
      begin
        if serial_obj[:serial_conn] && !serial_obj[:serial_conn].closed?
          to_radio = Meshtastic::ToRadio.new
          to_radio.disconnect = true
          send_to_radio(serial_obj: serial_obj, to_radio: to_radio)
          sleep 0.05
        end
      rescue StandardError
        # ignore during teardown
      end

      rx_thread = serial_obj[:rx_thread]
      serial_conn = serial_obj[:serial_conn]

      begin
        serial_conn&.close
      rescue StandardError
        nil
      end

      if rx_thread&.alive? && rx_thread != Thread.current
        rx_thread.join(1)
        rx_thread.kill if rx_thread.alive?
      end

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
      puts "        USAGE:
        # Run the request class method for this module.
        #{self}.request(
          serial_obj: 'optional - value for serial_obj passed into request',
          payload: 'optional - value for payload passed into request'
        )

        # Run the send_to_radio class method for this module.
        #{self}.send_to_radio(
          serial_obj: 'optional - value for serial_obj passed into send_to_radio',
          to_radio: 'optional - value for to_radio passed into send_to_radio'
        )

        # Run the connect class method for this module.
        #{self}.connect(
          block_dev: 'optional - value for block_dev passed into connect',
          baud: 'optional - value for baud passed into connect',
          data_bits: 'optional - value for data_bits passed into connect',
          stop_bits: 'optional - value for stop_bits passed into connect',
          parity: 'optional - value for parity passed into connect',
          debug_out: 'optional - value for debug_out passed into connect'
        )

        # Run the wait_for_config class method for this module.
        #{self}.wait_for_config(
          serial_obj: 'optional - value for serial_obj passed into wait_for_config'
        )

        # Run the wake_up_device class method for this module.
        #{self}.wake_up_device(
          serial_obj: 'optional - value for serial_obj passed into wake_up_device'
        )

        # Run the dump_stdout_data class method for this module.
        #{self}.dump_stdout_data(
          type: 'optional - value for type passed into dump_stdout_data',
          serial_obj: 'optional - value for serial_obj passed into dump_stdout_data'
        )

        # Run the flush_data class method for this module.
        #{self}.flush_data(
          type: 'optional - value for type passed into flush_data',
          serial_obj: 'optional - value for serial_obj passed into flush_data'
        )

        # Run the drain_from_radio class method for this module.
        #{self}.drain_from_radio(
          max: 'optional - value for max passed into drain_from_radio',
          serial_obj: 'optional - value for serial_obj passed into drain_from_radio'
        )

        # Run the recv_from_radio class method for this module.
        #{self}.recv_from_radio(
          serial_obj: 'optional - value for serial_obj passed into recv_from_radio'
        )

        # Run the monitor_stdout class method for this module.
        #{self}.monitor_stdout(
          serial_obj: 'optional - value for serial_obj passed into monitor_stdout',
          type: 'optional - value for type passed into monitor_stdout',
          refresh: 'optional - value for refresh passed into monitor_stdout',
          include: 'optional - value for include passed into monitor_stdout',
          exclude: 'optional - value for exclude passed into monitor_stdout'
        )

        # Run the subscribe class method for this module.
        #{self}.subscribe(
          serial_obj: 'optional - value for serial_obj passed into subscribe',
          psks: 'optional - value for psks passed into subscribe',
          exclude: 'optional - value for exclude passed into subscribe',
          include: 'optional - value for include passed into subscribe',
          gps_metadata: 'optional - value for gps_metadata passed into subscribe',
          include_raw: 'optional - value for include_raw passed into subscribe',
          timeout: 'optional - value for timeout passed into subscribe'
        )

        # Run the send_text class method for this module.
        #{self}.send_text(
          serial_obj: 'optional - value for serial_obj passed into send_text',
          via: 'optional - value for via passed into send_text',
          channel: 'optional - value for channel passed into send_text',
          from: 'optional - value for from passed into send_text',
          psks: 'optional - value for psks passed into send_text',
          text: 'optional - value for text passed into send_text'
        )

        # Run the send_data class method for this module.
        #{self}.send_data(
          serial_obj: 'optional - value for serial_obj passed into send_data',
          via: 'optional - value for via passed into send_data',
          channel: 'optional - value for channel passed into send_data',
          psks: 'optional - value for psks passed into send_data',
          from: 'optional - value for from passed into send_data'
        )

        # Run the disconnect class method for this module.
        #{self}.disconnect(
          serial_obj: 'optional - value for serial_obj passed into disconnect'
        )

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
