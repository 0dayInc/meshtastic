# frozen_string_literal: true

require 'socket'

# Meshtastic client API over TCP. Framing matches Serial (START1/START2 + protobuf).
# Default port is 4403, same as the official TCP interface.
module Meshtastic
  module TCP
    DEFAULT_PORT = 4403

    def self.connect(opts = {})
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

    def self.wait_for_config(opts = {})
      Meshtastic::Serial.wait_for_config(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    def self.send_to_radio(opts = {})
      Meshtastic::Serial.send_to_radio(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    def self.send_text(opts = {})
      Meshtastic::Serial.send_text(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    def self.send_data(opts = {})
      Meshtastic::Serial.send_data(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    def self.recv_from_radio(opts = {})
      Meshtastic::Serial.recv_from_radio(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    def self.drain_from_radio(opts = {})
      Meshtastic::Serial.drain_from_radio(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]))
    end

    def self.subscribe(opts = {}, &)
      Meshtastic::Serial.subscribe(opts.merge(serial_obj: opts[:tcp_obj] || opts[:serial_obj]), &)
    end

    def self.disconnect(opts = {})
      Meshtastic::Serial.disconnect(serial_obj: opts[:tcp_obj] || opts[:serial_obj])
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "Send and receive Meshtastic messages over TCP (default port #{DEFAULT_PORT}).

      USAGE:
        tcp_obj = #{self}.connect(
          host: 'optional - (default: 127.0.0.1)',
          port: 'optional - (default: 4403)',
          want_config: 'optional - request full node DB after connect (default: true)'
        )

        #{self}.wait_for_config(tcp_obj: tcp_obj, timeout: 10)
        #{self}.send_text(tcp_obj: tcp_obj, to: '!ffffffff', channel: 0, text: 'Hello over TCP!')
        #{self}.subscribe(tcp_obj: tcp_obj, include: 'TEXT_MESSAGE_APP')
        #{self}.disconnect(tcp_obj: tcp_obj)
        #{self}.authors
      "
    end
  end
end
