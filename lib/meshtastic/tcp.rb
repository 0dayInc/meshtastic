# frozen_string_literal: true

require 'socket'

# Meshtastic client API over TCP. Framing matches Serial (START1/START2 + protobuf).
# Default port is 4403, same as the official TCP interface.
module Meshtastic
  module TCP
    DEFAULT_PORT = 4403

    public_class_method def self.connect(opts = {})
      host = opts[:host] ||= '127.0.0.1'
      port = opts[:port] ||= DEFAULT_PORT
      tcp_obj = nil
      socket = opts[:socket] || TCPSocket.new(host, port)
      socket.binmode

      tcp_obj = {
        serial_conn: socket,
        tcp_socket: socket,
        block_dev: "#{host}:#{port}",
        host: host,
        port: port,
        tx_mutex: Mutex.new,
        my_info: nil,
        my_node_num: nil,
        metadata: nil
      }
      tcp_obj[:rx_thread] = Meshtastic::Serial.send(
        :init_rx_thread,
        serial_conn: socket,
        serial_obj: tcp_obj,
        debug_out: opts[:debug_out]
      )
      Meshtastic::Serial.wake_up_device(serial_obj: tcp_obj)
      if opts.fetch(:want_config, true)
        mesh = Meshtastic::MeshInterface.new
        bytes = mesh.start_config
        tcp_obj[:config_id] = mesh.config_id
        Meshtastic::Serial.send_to_radio(serial_obj: tcp_obj, to_radio: bytes)
      end
      tcp_obj
    rescue StandardError
      disconnect(tcp_obj: tcp_obj) if tcp_obj
      raise
    end

    public_class_method def self.wait_for_config(opts = {})
      Meshtastic::Serial.wait_for_config(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    public_class_method def self.send_to_radio(opts = {})
      Meshtastic::Serial.send_to_radio(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    public_class_method def self.send_text(opts = {})
      Meshtastic::Serial.send_text(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    public_class_method def self.send_data(opts = {})
      Meshtastic::Serial.send_data(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    public_class_method def self.recv_from_radio(opts = {})
      Meshtastic::Serial.recv_from_radio(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    public_class_method def self.drain_from_radio(opts = {})
      Meshtastic::Serial.drain_from_radio(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    public_class_method def self.subscribe(opts = {})
      merged = opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj])
      if block_given?
        Meshtastic::Serial.subscribe(merged) { |msg| yield msg } # rubocop:disable Style/ExplicitBlockArgument
      else
        Meshtastic::Serial.subscribe(merged)
      end
    end

    public_class_method def self.disconnect(opts = {})
      Meshtastic::Serial.disconnect(serial_obj: opts[:tcp_obj] || opts[:serial_obj])
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the connect class method for this module.
        #{self}.connect(
          host: 'optional - value for host passed into connect',
          port: 'optional - value for port passed into connect',
          socket: 'optional - value for socket passed into connect',
          debug_out: 'optional - value for debug_out passed into connect'
        )

        # Run the wait_for_config class method for this module.
        #{self}.wait_for_config(
          tcp_obj: 'optional - value for tcp_obj passed into wait_for_config',
          serial_obj: 'optional - value for serial_obj passed into wait_for_config'
        )

        # Run the send_to_radio class method for this module.
        #{self}.send_to_radio(
          tcp_obj: 'optional - value for tcp_obj passed into send_to_radio',
          serial_obj: 'optional - value for serial_obj passed into send_to_radio'
        )

        # Run the send_text class method for this module.
        #{self}.send_text(
          tcp_obj: 'optional - value for tcp_obj passed into send_text',
          serial_obj: 'optional - value for serial_obj passed into send_text'
        )

        # Run the send_data class method for this module.
        #{self}.send_data(
          tcp_obj: 'optional - value for tcp_obj passed into send_data',
          serial_obj: 'optional - value for serial_obj passed into send_data'
        )

        # Run the recv_from_radio class method for this module.
        #{self}.recv_from_radio(
          tcp_obj: 'optional - value for tcp_obj passed into recv_from_radio',
          serial_obj: 'optional - value for serial_obj passed into recv_from_radio'
        )

        # Run the drain_from_radio class method for this module.
        #{self}.drain_from_radio(
          tcp_obj: 'optional - value for tcp_obj passed into drain_from_radio',
          serial_obj: 'optional - value for serial_obj passed into drain_from_radio'
        )

        # Run the subscribe class method for this module.
        #{self}.subscribe(
          tcp_obj: 'optional - value for tcp_obj passed into subscribe',
          serial_obj: 'optional - value for serial_obj passed into subscribe'
        )

        # Run the disconnect class method for this module.
        #{self}.disconnect(
          tcp_obj: 'optional - value for tcp_obj passed into disconnect',
          serial_obj: 'optional - value for serial_obj passed into disconnect'
        )

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
