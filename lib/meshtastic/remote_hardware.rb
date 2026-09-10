# frozen_string_literal: true

require 'meshtastic/mesh_pb'

module Meshtastic
  module RemoteHardware
    public_class_method def self.encode(opts = {})
      message = Meshtastic::HardwareMessage.new
      message.type = opts.fetch(:type, :READ_GPIOS)
      message.gpio_mask = opts.fetch(:gpio_mask, 0)
      message.gpio_value = opts[:gpio_value].to_i if opts[:gpio_value]
      message
    end

    public_class_method def self.send(opts = {})
      data = Meshtastic::Data.new(
        portnum: :REMOTE_HARDWARE_APP,
        payload: encode(opts).to_proto,
        want_response: opts.fetch(:want_response, true)
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::REMOTE_HARDWARE_APP))
    end

    public_class_method def self.read_gpios(opts = {})
      send(opts.merge(type: :READ_GPIOS))
    end

    public_class_method def self.write_gpios(opts = {})
      send(opts.merge(type: :WRITE_GPIOS, want_response: false))
    end

    public_class_method def self.watch_gpios(opts = {})
      send(opts.merge(type: :WATCH_GPIOS))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the encode class method for this module.
        #{self}.encode(
          gpio_value: 'optional - value for gpio_value passed into encode'
        )

        # Run the send class method for this module.
        #{self}.send

        # Run the read_gpios class method for this module.
        #{self}.read_gpios

        # Run the write_gpios class method for this module.
        #{self}.write_gpios

        # Run the watch_gpios class method for this module.
        #{self}.watch_gpios

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
