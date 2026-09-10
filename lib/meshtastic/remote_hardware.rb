# frozen_string_literal: true

require 'meshtastic/mesh_pb'

module Meshtastic
  module RemoteHardware
    def self.encode(opts = {})
      message = Meshtastic::HardwareMessage.new
      message.type = opts.fetch(:type, :READ_GPIOS)
      message.gpio_mask = opts.fetch(:gpio_mask, 0)
      message.gpio_value = opts[:gpio_value].to_i if opts[:gpio_value]
      message
    end

    def self.send(opts = {})
      data = Meshtastic::Data.new(
        portnum: :REMOTE_HARDWARE_APP,
        payload: encode(opts).to_proto,
        want_response: opts.fetch(:want_response, true)
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::REMOTE_HARDWARE_APP))
    end

    def self.read_gpios(opts = {})
      send(opts.merge(type: :READ_GPIOS))
    end

    def self.write_gpios(opts = {})
      send(opts.merge(type: :WRITE_GPIOS, want_response: false))
    end

    def self.watch_gpios(opts = {})
      send(opts.merge(type: :WATCH_GPIOS))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.read_gpios(serial_obj: serial_obj, gpio_mask: 0x01)
        #{self}.write_gpios(serial_obj: serial_obj, gpio_mask: 0x01, gpio_value: 0x01)
        #{self}.watch_gpios(serial_obj: serial_obj, gpio_mask: 0x01)
        #{self}.authors
      "
    end
  end
end
