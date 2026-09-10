# frozen_string_literal: true

require 'meshtastic/admin_pb'

module Meshtastic
  module Admin
    def self.encode(opts = {})
      message = opts[:message] || Meshtastic::AdminMessage.new
      opts.each do |key, value|
        next if %i[message serial_obj bluetooth_obj tcp_obj to from channel want_ack hop_limit].include?(key)
        next unless message.respond_to?("#{key}=")

        message.public_send("#{key}=", value)
      end
      message
    end

    def self.send(opts = {})
      message = encode(opts)
      data = Meshtastic::Data.new(
        portnum: :ADMIN_APP,
        payload: message.to_proto,
        want_response: opts.fetch(:want_response, true)
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::ADMIN_APP))
    end

    def self.reboot(opts = {})
      send(opts.merge(reboot_seconds: opts.fetch(:seconds, 5)))
    end

    def self.shutdown(opts = {})
      send(opts.merge(shutdown_seconds: opts.fetch(:seconds, 5)))
    end

    def self.set_owner(opts = {})
      user = opts[:owner] || Meshtastic::User.new(long_name: opts[:long_name], short_name: opts[:short_name])
      send(opts.merge(set_owner: user))
    end

    def self.get_owner(opts = {})
      send(opts.merge(get_owner_request: true))
    end

    def self.set_channel(opts = {})
      send(opts.merge(set_channel: opts.fetch(:channel_settings)))
    end

    def self.get_channel(opts = {})
      send(opts.merge(get_channel_request: opts.fetch(:index, 0)))
    end

    def self.get_config(opts = {})
      send(opts.merge(get_config_request: opts.fetch(:config_type, :DEVICE_CONFIG)))
    end

    def self.set_config(opts = {})
      send(opts.merge(set_config: opts.fetch(:config)))
    end

    def self.nodedb_reset(opts = {})
      send(opts.merge(nodedb_reset: true))
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.reboot(serial_obj: serial_obj, seconds: 5)
        #{self}.shutdown(serial_obj: serial_obj, seconds: 5)
        #{self}.get_owner(serial_obj: serial_obj)
        #{self}.set_owner(serial_obj: serial_obj, long_name: 'Node', short_name: 'N1')
        #{self}.get_channel(serial_obj: serial_obj, index: 0)
        #{self}.get_config(serial_obj: serial_obj, config_type: :LORA_CONFIG)
        #{self}.nodedb_reset(serial_obj: serial_obj)
        #{self}.authors
      "
    end
  end
end
