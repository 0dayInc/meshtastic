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
  module SerialInterface # rubocop:disable Metrics/ModuleLength
    @console_data = []
    @proto_data = []
    @from_radio_queue = nil
    @rx_mutex = Mutex.new
    @want_exit = false

    module_function

    # ---- low-level IO helpers ------------------------------------------------

    def self.clear_hupcl(block_dev)
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
    private_class_method :clear_hupcl

    # Supported Method Parameters::
    # proto_thread = init_rx_thread(
    #   serial_conn: 'required - File returned from UART.open',
    #   serial_obj:  'required - serial_obj hash being built'
    # )
    private_class_method def self.init_rx_thread(opts = {})
      serial_conn = opts[:serial_conn]
      serial_obj = opts[:serial_obj]
      debug_out = opts[:debug_out]

      @want_exit = false
      @from_radio_queue = Queue.new
      @console_data = []
      @proto_data = []

      Thread.new do
        Thread.current.abort_on_exception = false
        rx_buf = +''.b
        empty = +''.b

        until @want_exit
          begin
            chunk = serial_conn.read(1)
            if chunk.nil? || chunk.empty?
              sleep 0.01
              next
            end

            c = chunk.getbyte(0)
            rx_buf << chunk
            ptr = rx_buf.bytesize - 1

            if ptr.zero?
              # looking for START1
              unless c == Meshtastic::START1
                rx_buf = empty.dup
                append_console_byte(chunk, debug_out)
              end
            elsif ptr == 1
              # looking for START2
              rx_buf = empty.dup unless c == Meshtastic::START2
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
          rescue IOError, Errno::EBADF, Errno::EIO
            break if @want_exit

            sleep 0.05
          rescue StandardError => e
            warn "Meshtastic::SerialInterface RX error: #{e.class}: #{e.message}" unless @want_exit
            sleep 0.05
          end
        end
      end
    end


    private_class_method def self.append_console_byte(chunk, debug_out)
      if debug_out
        begin
          debug_out.write(chunk.force_encoding('UTF-8'))
        rescue StandardError
          debug_out.write('?')
        end
      else
        @rx_mutex.synchronize { @console_data << chunk.force_encoding('UTF-8') }
      end
    end

    private_class_method def self.handle_from_radio_bytes(opts = {})
      payload = opts[:payload]
      serial_obj = opts[:serial_obj]
      return if payload.nil? || payload.empty?

      from_radio = Meshtastic::FromRadio.decode(payload)
      hash = from_radio.to_h

      @rx_mutex.synchronize { @proto_data << hash }
      @from_radio_queue << from_radio if @from_radio_queue

      # Cache useful device identity on the serial_obj handle.
      if serial_obj && from_radio.my_info
        serial_obj[:my_info] = from_radio.my_info.to_h
        serial_obj[:my_node_num] = from_radio.my_info.my_node_num
      end
      serial_obj[:metadata] = from_radio.metadata.to_h if serial_obj && from_radio.metadata

      if from_radio.log_record
        msg = from_radio.log_record.message.to_s
        @rx_mutex.synchronize { @console_data << "#{msg}\n" } unless msg.empty?
      end

      from_radio
    rescue Google::Protobuf::ParseError => e
      warn "Meshtastic::SerialInterface: failed to decode FromRadio (#{e.message})"
      nil
    end

    # ---- public API ----------------------------------------------------------

    # Supported Method Parameters::
    # Meshtastic::SerialInterface.request(
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

      serial_conn.write(bytes)
      serial_conn.flush
      sleep 0.05
      bytes.bytesize
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::SerialInterface.send_to_radio(
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
    # serial_obj = Meshtastic::SerialInterface.connect(
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

      clear_hupcl(block_dev)

      serial_conn = UART.open(block_dev, baud, mode)

      serial_obj = {
        serial_conn: serial_conn,
        block_dev: block_dev,
        baud: baud,
        my_info: nil,
        my_node_num: nil,
        metadata: nil
      }

      serial_obj[:rx_thread] = init_rx_thread(
        serial_conn: serial_conn,
        serial_obj: serial_obj,
        debug_out: debug_out
      )

      # Wake / resync the device's framing state-machine.
      wake_up_device(serial_obj: serial_obj)

      if want_config
        mui = Meshtastic::MeshInterface.new
        to_radio_bytes = mui.start_config
        send_to_radio(serial_obj: serial_obj, to_radio: to_radio_bytes)
      end

      serial_obj
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
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
    # stdout_data = Meshtastic::SerialInterface.dump_stdout_data(
    #   type: 'required - :proto or :console'
    # )
    public_class_method def self.dump_stdout_data(opts = {})
      type = opts[:type]
      valid_types = %i[proto console]
      raise "ERROR: Invalid type: #{type}. Supported types are :proto or :console" unless valid_types.include?(type)

      @rx_mutex.synchronize do
        if block_given?
          if type == :proto
            @proto_data.each { |proto_hash| yield proto_hash }
          else
            @console_data.join.split("\n").each { |line| yield line.force_encoding('UTF-8') }
          end
          nil
        else
          type == :proto ? @proto_data.dup : @console_data.join
        end
      end
    end

    # Supported Method Parameters::
    # Meshtastic::SerialInterface.flush_data(
    #   type: 'required - :proto or :console'
    # )
    public_class_method def self.flush_data(opts = {}) # rubocop:disable Naming/PredicateMethod
      type = opts[:type]
      valid_types = %i[proto console]
      raise "ERROR: Invalid type: #{type}. Supported types are :proto or :console" unless valid_types.include?(type)

      @rx_mutex.synchronize do
        @console_data.clear if type == :console
        @proto_data.clear if type == :proto
      end
      true
    end

    # Drain the FromRadio queue without blocking (returns Array of FromRadio msgs).
    public_class_method def self.drain_from_radio(opts = {})
      max = opts[:max] ||= 256
      msgs = []
      return msgs unless @from_radio_queue

      max.times do
          msgs << @from_radio_queue.pop(true)
      rescue ThreadError
          break
      end
      msgs
    end

    # Block until a FromRadio arrives or timeout (seconds). Returns FromRadio or nil.
    public_class_method def self.recv_from_radio(opts = {})
      timeout = opts[:timeout] ||= 5
      raise 'ERROR: RX queue not initialised — call connect first' unless @from_radio_queue

      if timeout.nil? || timeout.negative?
        @from_radio_queue.pop
      else
        begin
          Timeout.timeout(timeout) { @from_radio_queue.pop }
        rescue Timeout::Error
          nil
        end
      end
    end

    # Supported Method Parameters::
    # Meshtastic::SerialInterface.monitor_stdout(
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

        dump_stdout_data(type: type) do |data|
          data_s = data.is_a?(Hash) ? data.inspect : data.to_s
          disp = !exclude_arr.intersect?(data_s) && (
                   include_arr.empty? ||
                   include_arr.all? { |inc| data_s.include?(inc) }
                 )
          puts data_s if disp
        end
        flush_data(type: type)
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

      encrypted_message = message[:encrypted]
      if encrypted_message.to_s.length.positive? && psks.any?
        packet_id = message[:id]
        packet_from = message[:from]
        nonce_packet_id = [packet_id].pack('V').ljust(8, "\x00")
        nonce_from_node = [packet_from].pack('V').ljust(8, "\x00")
        nonce = "#{nonce_packet_id}#{nonce_from_node}"

        psk = psks[:LongFast] || psks[psks.keys.first]
        dec_psk = Base64.strict_decode64(psk)

        cipher = OpenSSL::Cipher.new(dec_psk.length == 32 ? 'AES-256-CTR' : 'AES-128-CTR')
        cipher.decrypt
        cipher.key = dec_psk
        cipher.iv = nonce
        decrypted = cipher.update(encrypted_message) + cipher.final
        message[:decoded] = Meshtastic::Data.decode(decrypted).to_h
        message[:encrypted] = :decrypted
      end

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
    # Meshtastic::SerialInterface.subscribe(
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
        from_radio =
          if timeout
            recv_from_radio(timeout: timeout)
          else
            @from_radio_queue.pop
          end
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

          disp = !exclude_arr.intersect?(flat_message) &&
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
    # Meshtastic::SerialInterface.send_text(
    #   serial_obj: 'required - serial_obj returned from #connect method',
    #   from: 'optional - From ID (Default: local my_node_num or "!00000b0b")',
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

      if opts[:from].nil?
        opts[:from] =
          if serial_obj[:my_node_num]
            "!#{serial_obj[:my_node_num].to_s(16)}"
          else
            '!00000b0b'
          end
      end

      # Device performs channel encryption for serial ToRadio packets.
      # Pass empty psks so MeshInterface leaves the payload in :decoded form.
      opts[:psks] = nil

      mui = Meshtastic::MeshInterface.new
      protobuf = mui.send_text(opts)
      send_to_radio(serial_obj: serial_obj, to_radio: protobuf)
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::SerialInterface.send_data(
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
      opts[:from] = "!#{serial_obj[:my_node_num].to_s(16)}" if opts[:from].nil? && serial_obj[:my_node_num]

      mui = Meshtastic::MeshInterface.new
      protobuf = mui.send_data(opts)
      send_to_radio(serial_obj: serial_obj, to_radio: protobuf)
    rescue StandardError => e
      disconnect(serial_obj: serial_obj) unless serial_obj.nil?
      raise e
    end

    # Supported Method Parameters::
    # serial_obj = Meshtastic::SerialInterface.disconnect(
    #   serial_obj: 'required - serial_obj returned from #connect method'
    # )
    public_class_method def self.disconnect(opts = {})
      serial_obj = opts[:serial_obj]
      return nil unless serial_obj

      @want_exit = true

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
      puts "USAGE:
        serial_obj = #{self}.connect(
          block_dev: 'optional - serial block device path (defaults to /dev/ttyUSB0)',
          baud: 'optional - (defaults to 115200)',
          data_bits: 'optional - (defaults to 8)',
          stop_bits: 'optional - (defaults to 1)',
          parity: 'optional - :even|:odd|:none (defaults to :none)',
          debug_out: 'optional - IO receiving non-protobuf debug console bytes',
          want_config: 'optional - request full node DB after connect (default: true)'
        )

        #{self}.wake_up_device(
          serial_obj: 'required - serial_obj returned from #connect method'
        )

        #{self}.request(
          serial_obj: 'required serial_obj returned from #connect method',
          payload: 'required - array of bytes OR string to write to serial device'
        )

        #{self}.send_to_radio(
          serial_obj: 'required - serial_obj returned from #connect method',
          to_radio: 'required - Meshtastic::ToRadio OR serialized String'
        )

        from_radio = #{self}.recv_from_radio(
          timeout: 'optional - seconds (default: 5; nil = block forever)'
        )

        msgs = #{self}.drain_from_radio(max: 256)

        stdout_data = #{self}.dump_stdout_data(
          type: 'required - :proto or :console'
        )

        #{self}.flush_data(
          type: 'required - :console or :proto'
        )

        #{self}.monitor_stdout(
          serial_obj: 'required - serial_obj returned from #connect method',
          type: 'required - :proto or :console',
          refresh: 'optional - refresh interval (default: 3)',
          include: 'optional - comma-delimited string(s) to include in message',
          exclude: 'optional - comma-delimited string(s) to exclude in message'
        )

        #{self}.subscribe(
          serial_obj: 'required - serial_obj returned from #connect method',
          psks: 'optional - hash of :channel_id => psk (default: { LongFast: \"AQ==\" })',
          exclude: 'optional - comma-delimited string(s) to exclude',
          include: 'optional - comma-delimited string(s) to include',
          gps_metadata: 'optional - include GPS metadata (default: false)',
          include_raw: 'optional - include raw packet bytes (default: false)',
          timeout: 'optional - seconds per pop (default: nil = forever)'
        )

        #{self}.send_text(
          serial_obj: 'required - serial_obj returned from #connect method',
          from: 'optional - From ID (Default: local my_node_num or \"!00000b0b\")',
          to: 'optional - Destination ID (Default: \"!ffffffff\")',
          channel: 'optional - channel index (Default: 0)',
          text: 'optional - Text Message (Default: SYN)',
          want_ack: 'optional - Want Acknowledgement (Default: false)',
          want_response: 'optional - Want Response (Default: false)',
          hop_limit: 'optional - Hop Limit (Default: 3)'
        )

        #{self}.send_data(
          serial_obj: 'required - serial_obj returned from #connect method',
          from: 'optional - From ID',
          to: 'optional - Destination ID (Default: \"!ffffffff\")',
          channel: 'optional - channel index (Default: 0)',
          data: 'required - Meshtastic::Data',
          want_ack: 'optional - Want Acknowledgement (Default: false)',
          hop_limit: 'optional - Hop Limit (Default: 3)',
          port_num: 'optional - PortNum (Default: PRIVATE_APP)'
        )

        serial_obj = #{self}.disconnect(
          serial_obj: 'required - serial_obj returned from #connect method'
        )

        #{self}.authors
      "
    end
  end
end
