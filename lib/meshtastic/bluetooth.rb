# frozen_string_literal: true

require 'json'
require 'timeout'

# Meshtastic client API over Bluetooth Low Energy, using Linux BlueZ and Ruby D-Bus.
module Meshtastic
  module Bluetooth
    autoload :BlueZ, 'meshtastic/bluetooth/bluez'

    def self.scan(opts = {})
      BlueZ.scan(adapter: opts.fetch(:adapter, 'hci0'), timeout: opts.fetch(:timeout, 5))
    end

    # Connect to an already paired BLE address (not a mesh node ID).
    def self.connect(opts = {})
      connection = BlueZ.new(address: opts[:address], adapter: opts.fetch(:adapter, 'hci0'), timeout: opts.fetch(:timeout, 15))
      connection.connect
      bluetooth_obj = {
        bluetooth_conn: connection, address: opts[:address], tx_mutex: Mutex.new,
        rx_mutex: Mutex.new, from_radio_queue: Queue.new, config_queue: Queue.new,
        proto_data: [], console_data: []
      }
      bluetooth_obj[:rx_thread] = start_reader(bluetooth_obj)
      if opts.fetch(:want_config, true)
        mesh = Meshtastic::MeshInterface.new
        bytes = mesh.start_config
        bluetooth_obj[:config_id] = mesh.config_id
        send_to_radio(bluetooth_obj: bluetooth_obj, to_radio: bytes)
      end
      @last_bluetooth_obj = bluetooth_obj
      bluetooth_obj
    rescue StandardError
      bluetooth_obj ? disconnect(bluetooth_obj: bluetooth_obj) : connection&.close
      raise
    end

    private_class_method def self.start_reader(handle)
      Thread.new do
        until handle[:closing]
          bytes = handle[:bluetooth_conn].read
          if bytes.empty?
            sleep 0.1
            next
          end
          receive_bytes(handle, bytes)
        end
      rescue StandardError => e
        handle[:rx_error] = IOError.new("Bluetooth receive failed: #{e.message}") unless handle[:closing]
      ensure
        handle[:from_radio_queue].close
        handle[:config_queue].close
      end
    end

    private_class_method def self.receive_bytes(handle, bytes)
      message = Meshtastic::FromRadio.decode(bytes)
      if message.my_info
        handle[:my_info] = message.my_info.to_h
        handle[:my_node_num] = message.my_info.my_node_num
      end
      handle[:metadata] = message.metadata.to_h if message.metadata
      handle[:rx_mutex].synchronize do
        handle[:proto_data] << message.to_h
        handle[:console_data] << "#{message.log_record.message}\n" if message.log_record
      end
      handle[:from_radio_queue] << message
      if message.payload_variant == :config_complete_id && message.config_complete_id == handle[:config_id]
        handle[:config_complete] = true
        handle[:config_queue].close
      end
    rescue Google::Protobuf::ParseError => e
      warn "Meshtastic::Bluetooth: failed to decode FromRadio (#{e.message})"
    end

    private_class_method def self.handle_for(opts)
      handle = opts[:bluetooth_obj] || @last_bluetooth_obj
      raise ArgumentError, 'bluetooth_obj is required; call connect first' unless handle

      handle
    end

    def self.wait_for_config(opts = {})
      handle = handle_for(opts)
      raise ArgumentError, 'connect with want_config: true first' unless handle[:config_id]

      handle[:config_queue].pop(timeout: opts.fetch(:timeout, 10))
      raise handle[:rx_error] if handle[:rx_error]
      raise IOError, 'Bluetooth connection closed' if handle[:closing]
      raise Timeout::Error, "No configuration response from #{handle[:address]}" unless handle[:config_complete]

      handle
    end

    def self.recv_from_radio(opts = {})
      handle = handle_for(opts)
      timeout = opts.fetch(:timeout, 5)
      timeout = nil if timeout&.negative?
      message = handle[:from_radio_queue].pop(timeout: timeout)
      raise handle[:rx_error] if message.nil? && handle[:rx_error]

      message
    end

    def self.drain_from_radio(opts = {})
      handle = handle_for(opts)
      messages = []
      opts.fetch(:max, 256).times do
        message = recv_from_radio(bluetooth_obj: handle, timeout: 0)
        break unless message

        messages << message
      end
      messages
    end

    def self.dump_stdout_data(opts = {}, &)
      Meshtastic::Serial.dump_stdout_data(opts.merge(serial_obj: handle_for(opts)), &)
    end

    def self.flush_data(opts = {})
      Meshtastic::Serial.flush_data(opts.merge(serial_obj: handle_for(opts)))
    end

    # Yield the same enriched FromRadio hashes as Serial, without opening a UART.
    def self.subscribe(opts = {})
      handle = handle_for(opts)
      psks = opts.fetch(:psks, { LongFast: 'AQ==' }).dup
      raise ArgumentError, 'psks must be a hash' unless psks.is_a?(Hash)

      psks[:LongFast] = '1PG7OiApB1nwvP+rz05pAQ==' if psks[:LongFast] == 'AQ=='
      psks = Meshtastic::MeshInterface.new.get_cipher_keys(psks: psks)
      includes = opts[:include].to_s.split(',').map(&:strip)
      excludes = opts[:exclude].to_s.split(',').map(&:strip)
      loop do
        message = recv_from_radio(bluetooth_obj: handle, timeout: opts[:timeout])
        break if message.nil? && handle[:from_radio_queue].closed?
        next unless message

        decoded = message.to_h
        if decoded[:packet]
          # Share the existing pure packet decoder; BLE never uses Serial's IO methods.
          decoded[:packet] = Meshtastic::Serial.send(:enrich_packet,
                                                     message: decoded[:packet], psks: psks,
                                                     gps_metadata: opts[:gps_metadata], include_raw: opts[:include_raw],
                                                     raw_packet: opts[:include_raw] ? message.to_proto : nil)
        end
        source = decoded.inspect
        next unless includes.all? { |term| source.include?(term) } && excludes.none? { |term| source.include?(term) }

        if block_given?
          yield decoded
        else
          begin
            puts JSON.pretty_generate(decoded)
          rescue JSON::GeneratorError
            puts decoded.inspect
          end
        end
      end
    rescue Interrupt
      disconnect(bluetooth_obj: handle)
    rescue StandardError
      disconnect(bluetooth_obj: handle)
      raise
    end

    # Write one complete serialized ToRadio to GATT. BLE does not use UART headers.
    def self.send_to_radio(opts = {})
      handle = opts[:bluetooth_obj]
      raise ArgumentError, 'bluetooth_obj is required' unless handle
      raise IOError, 'Bluetooth connection closed' if handle[:closing]

      message = opts[:to_radio]
      body = case message
             when Meshtastic::ToRadio then message.to_proto
             when String then message.b
             else raise ArgumentError, 'to_radio must be Meshtastic::ToRadio or a serialized String'
             end
      raise ArgumentError, 'ToRadio payload exceeds 512 bytes' if body.bytesize > Meshtastic::MAX_TO_FROM_RADIO_SIZE

      begin
        handle[:tx_mutex].synchronize { handle[:bluetooth_conn].write(body) }
      rescue StandardError
        disconnect(bluetooth_obj: handle)
        raise
      end
    end

    def self.send_text(opts = {})
      handle = opts[:bluetooth_obj]
      raise ArgumentError, 'bluetooth_obj is required' unless handle

      text = opts.fetch(:text, 'SYN').to_s
      max_len = Meshtastic::Constants::DATA_PAYLOAD_LEN
      raise ArgumentError, "Text Length > #{max_len} Bytes" if text.bytesize > max_len

      args = opts.merge(text: text, via: :radio, psks: nil, channel: opts.fetch(:channel, 0), from: opts[:from] || handle[:my_node_num] || 0)
      send_to_radio(bluetooth_obj: handle, to_radio: Meshtastic::MeshInterface.new.send_text(args))
    end

    def self.send_data(opts = {})
      handle = opts[:bluetooth_obj]
      raise ArgumentError, 'bluetooth_obj is required' unless handle
      raise ArgumentError, 'data must be Meshtastic::Data' unless opts[:data].is_a?(Meshtastic::Data)

      args = opts.merge(via: :radio, psks: nil, channel: opts.fetch(:channel, 0), from: opts[:from] || handle[:my_node_num] || 0)
      send_to_radio(bluetooth_obj: handle, to_radio: Meshtastic::MeshInterface.new.send_data(args))
    end

    def self.disconnect(opts = {})
      handle = opts[:bluetooth_obj]
      return unless handle
      return if handle[:closing]

      handle[:closing] = true
      handle[:from_radio_queue].close
      handle[:config_queue].close
      begin
        handle[:tx_mutex].synchronize do
          handle[:bluetooth_conn].write(Meshtastic::ToRadio.new(disconnect: true).to_proto)
        end
      rescue StandardError
        # A lost BLE link cannot receive a disconnect request.
        nil
      ensure
        handle[:bluetooth_conn].close
        reader = handle[:rx_thread]
        reader.join(1) if reader && reader != Thread.current
      end
      nil
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "Send and receive Meshtastic messages over Bluetooth Low Energy (Linux BlueZ).
      BLE writes unframed ToRadio protobufs (no UART START1/START2 header). Pair first with bluetoothctl.

      USAGE:
        devices = #{self}.scan(
          adapter: 'optional - BlueZ adapter (default: hci0)',
          timeout: 'optional - discovery seconds (default: 5)'
        )

        bluetooth_obj = #{self}.connect(
          address: 'required - BLE address (AA:BB:CC:DD:EE:FF), not a mesh node ID',
          adapter: 'optional - BlueZ adapter (default: hci0)',
          timeout: 'optional - D-Bus/connect seconds (default: 15)',
          want_config: 'optional - request full node DB after connect (default: true)'
        )

        #{self}.wait_for_config(
          bluetooth_obj: 'required - bluetooth_obj connected with want_config: true',
          timeout: 'optional - seconds to await configuration (default: 10)'
        )

        #{self}.send_to_radio(
          bluetooth_obj: 'required - bluetooth_obj returned from #connect',
          to_radio: 'required - Meshtastic::ToRadio OR serialized String'
        )

        from_radio = #{self}.recv_from_radio(
          bluetooth_obj: 'optional - bluetooth_obj (default: most recently opened connection)',
          timeout: 'optional - seconds (default: 5; 0 = poll; nil = block forever)'
        )

        msgs = #{self}.drain_from_radio(bluetooth_obj: bluetooth_obj, max: 256)

        #{self}.subscribe(
          bluetooth_obj: 'required - bluetooth_obj returned from #connect',
          include: 'optional - comma-delimited string(s) to include',
          exclude: 'optional - comma-delimited string(s) to exclude'
        )

        #{self}.send_text(
          bluetooth_obj: 'required - bluetooth_obj returned from #connect',
          to: 'optional - Destination ID (Default: \"!ffffffff\")',
          channel: 'optional - channel index (Default: 0)',
          text: 'optional - Text Message (Default: SYN)',
          want_ack: 'optional - Want Acknowledgement (Default: false)'
        )

        #{self}.send_data(
          bluetooth_obj: 'required - bluetooth_obj returned from #connect',
          data: 'required - Meshtastic::Data',
          to: 'optional - Destination ID (Default: \"!ffffffff\")',
          channel: 'optional - channel index (Default: 0)'
        )

        #{self}.disconnect(bluetooth_obj: bluetooth_obj)

        #{self}.authors
      "
    end
  end
end
