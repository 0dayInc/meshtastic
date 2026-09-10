# frozen_string_literal: true

require 'meshtastic/atak_pb'
require 'meshtastic/portnums_pb'
require 'zlib'

module Meshtastic
  module ATAK
    V1_PORT = Meshtastic::PortNum::ATAK_PLUGIN
    V2_PORT = Meshtastic::PortNum::ATAK_PLUGIN_V2
    FORWARDER_PORT = Meshtastic::PortNum::ATAK_FORWARDER
    V2_UNCOMPRESSED = 0xFF
    COORD_SCALE = 10_000_000
    SKIP_KEYS = %i[
      serial_obj bluetooth_obj tcp_obj mqtt_obj to from channel want_ack hop_limit
      port_num data want_response via psks message extra_skip packet
    ].freeze

    public_class_method def self.encode(opts = {})
      encode_v1(opts.merge({}))
    end

    public_class_method def self.encode_v1(opts = {})
      packet = opts[:packet] || Meshtastic::TAKPacket.new
      packet.is_compressed = opts.fetch(:is_compressed, packet.is_compressed)
      packet.contact = contact_from(opts) if contact?(opts)
      packet.group = group_from(opts) if group?(opts)
      packet.status = status_from(opts) if status?(opts)
      packet.pli = pli_from(opts) if pli?(opts)
      packet.chat = chat_from(opts) if chat?(opts)
      packet.detail = opts[:detail] if opts[:detail]
      packet
    end

    public_class_method def self.build_v2(opts = {})
      packet = opts[:packet] || Meshtastic::TAKPacketV2.new
      assign_fields(opts.merge(message: packet, extra_skip: %i[packet lat lon altitude message to]))
      packet.latitude_i = scale_coord(value: opts[:lat]) if opts[:lat]
      packet.longitude_i = scale_coord(value: opts[:lon]) if opts[:lon]
      packet.altitude = opts[:altitude].to_i if opts[:altitude]
      packet.chat = chat_from(opts) if chat?(opts) && opts[:chat].nil?
      packet
    end

    public_class_method def self.wrap_v2(opts = {})
      packet = opts[:packet]
      [V2_UNCOMPRESSED].pack('C') + packet.to_proto
    end

    public_class_method def self.encode_v2(opts = {})
      wrap_v2(packet: build_v2(opts))
    end

    public_class_method def self.decode_v2(opts = {})
      bytes = (opts[:wire] || opts[:payload]).to_s.b
      raise ArgumentError, 'empty ATAK V2 payload' if bytes.empty?

      flags = bytes.getbyte(0)
      body = bytes.byteslice(1..)
      if flags == V2_UNCOMPRESSED
        Meshtastic::TAKPacketV2.decode(body)
      else
        raise ArgumentError,
              "compressed ATAK V2 dictionary id #{flags & 0x3F} is not unpacked (flags=0x#{flags.to_s(16)})"
      end
    end

    public_class_method def self.compress_cot(opts = {})
      Zlib::Deflate.deflate(opts[:cot].to_s)
    end

    public_class_method def self.decompress_cot(opts = {})
      bytes = opts[:payload].to_s.b
      bytes = bytes.byteslice(1..) if bytes.getbyte(0).zero? && bytes.bytesize > 1
      Zlib::Inflate.inflate(bytes)
    end

    public_class_method def self.decode(opts = {})
      payload = opts[:payload]
      portnum = normalize_port(portnum: opts[:portnum])
      case portnum
      when V1_PORT, :ATAK_PLUGIN
        Meshtastic::TAKPacket.decode(payload.to_s.b)
      when V2_PORT, :ATAK_PLUGIN_V2
        decode_v2(payload: payload)
      when FORWARDER_PORT, :ATAK_FORWARDER
        decompress_cot(payload: payload)
      else
        raise ArgumentError, "unsupported TAK portnum: #{opts[:portnum].inspect}"
      end
    end

    public_class_method def self.send(opts = {})
      send_v1(opts.merge({}))
    end

    public_class_method def self.send_v1(opts = {})
      deliver(opts.merge(port_num: V1_PORT, payload: encode_v1(opts).to_proto))
    end

    public_class_method def self.send_chat(opts = {})
      send_v1(opts.merge({}))
    end

    public_class_method def self.send_pli(opts = {})
      send_v1(opts.merge({}))
    end

    public_class_method def self.send_v2(opts = {})
      deliver(opts.merge(port_num: V2_PORT, payload: encode_v2(opts)))
    end

    public_class_method def self.send_cot(opts = {})
      payload = compress_cot(cot: opts[:cot])
      max_len = Meshtastic::Constants::DATA_PAYLOAD_LEN
      raise ArgumentError, "ERROR: CoT Length > #{max_len} Bytes after zlib" if payload.bytesize > max_len

      deliver(opts.merge(port_num: FORWARDER_PORT, payload: payload))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "USAGE:
        # Encode a V1 TAKPacket (alias of encode_v1).
        #{self}.encode(
          message: 'optional - GeoChat text body to place on the packet',
          packet: 'optional - existing Meshtastic::TAKPacket to fill instead of a new one'
        )

        # Build a V1 TAKPacket with GeoChat, PLI, contact, group, or status.
        #{self}.encode_v1(
          packet: 'optional - existing Meshtastic::TAKPacket to fill instead of a new one',
          detail: 'optional - raw CoT detail bytes for the V1 detail field'
        )

        # Build a V2 TAKPacketV2 with scaled lat/lon and typed payloads.
        #{self}.build_v2(
          packet: 'optional - existing Meshtastic::TAKPacketV2 to fill instead of a new one',
          chat: 'optional - Meshtastic::GeoChat object if not using message:',
          lat: 'optional - latitude in decimal degrees (stored times 1e7)',
          lon: 'optional - longitude in decimal degrees (stored times 1e7)',
          altitude: 'optional - altitude in meters as an integer'
        )

        # Prefix a TAKPacketV2 protobuf with the uncompressed V2 flags byte.
        #{self}.wrap_v2(
          packet: 'required - Meshtastic::TAKPacketV2 to serialize onto the wire'
        )

        # Build and wrap an uncompressed V2 wire frame.
        #{self}.encode_v2(
          message: 'optional - GeoChat text for the V2 chat variant'
        )

        # Decode an uncompressed V2 wire frame (flags 0xFF plus protobuf).
        #{self}.decode_v2(
          wire: 'optional - full V2 wire bytes including the flags byte',
          payload: 'optional - same as wire when wire is omitted'
        )

        # zlib-compress Cursor-on-Target XML for ATAK_FORWARDER.
        #{self}.compress_cot(
          cot: 'required - CoT XML string to deflate for the forwarder port'
        )

        # zlib-decompress ATAK_FORWARDER payload bytes back to CoT XML.
        #{self}.decompress_cot(
          payload: 'required - zlib bytes from an ATAK_FORWARDER Data payload'
        )

        # Dispatch decode by Meshtastic TAK portnum.
        #{self}.decode(
          payload: 'required - raw port payload bytes from a decoded mesh Data',
          portnum: 'required - :ATAK_PLUGIN, :ATAK_PLUGIN_V2, or :ATAK_FORWARDER'
        )

        # Send a V1 TAKPacket (alias of send_v1).
        #{self}.send(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          message: 'optional - GeoChat text to send on ATAK_PLUGIN'
        )

        # Send a V1 TAKPacket on ATAK_PLUGIN (port 72).
        #{self}.send_v1(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          bluetooth_obj: 'optional - BLE handle from Meshtastic::Bluetooth.connect',
          tcp_obj: 'optional - TCP handle from Meshtastic::TCP.connect'
        )

        # Send V1 GeoChat on ATAK_PLUGIN.
        #{self}.send_chat(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          message: 'optional - GeoChat text body to transmit'
        )

        # Send V1 PLI on ATAK_PLUGIN.
        #{self}.send_pli(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          lat: 'optional - latitude in decimal degrees (stored times 1e7)',
          lon: 'optional - longitude in decimal degrees (stored times 1e7)'
        )

        # Send an uncompressed V2 frame on ATAK_PLUGIN_V2 (port 78).
        #{self}.send_v2(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          message: 'optional - GeoChat text for the V2 chat variant'
        )

        # Send zlib-compressed CoT XML on ATAK_FORWARDER (port 257).
        #{self}.send_cot(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          cot: 'required - CoT XML string small enough to fit after zlib'
        )

        # Print the AUTHOR(S) string for this module.
        #{self}.authors
      "
    end

    private_class_method def self.deliver(opts = {})
      data = Meshtastic::Data.new(portnum: opts[:port_num], payload: opts[:payload])
      Meshtastic.deliver_data(opts.merge(data: data, port_num: opts[:port_num]))
    end

    private_class_method def self.scale_coord(opts = {})
      (opts[:value].to_f * COORD_SCALE).round
    end

    private_class_method def self.normalize_port(opts = {})
      portnum = opts[:portnum]
      return portnum if portnum.is_a?(Integer)
      return Meshtastic::PortNum.resolve(portnum) if portnum.is_a?(Symbol)

      portnum
    end

    private_class_method def self.assign_fields(opts = {})
      message = opts[:message]
      skip = SKIP_KEYS + Array(opts[:extra_skip])
      opts.each do |key, value|
        next if skip.include?(key)
        next unless message.respond_to?("#{key}=")

        message.public_send("#{key}=", value)
      end
      message
    end

    private_class_method def self.contact?(opts = {})
      opts[:contact] || opts[:callsign] || opts[:device_callsign]
    end

    private_class_method def self.group?(opts = {})
      opts[:group] || opts[:team] || opts[:role]
    end

    private_class_method def self.status?(opts = {})
      opts[:status] || opts[:battery]
    end

    private_class_method def self.pli?(opts = {})
      opts[:pli] || opts[:lat] || opts[:lon]
    end

    private_class_method def self.chat?(opts = {})
      opts[:chat] || opts[:message]
    end

    private_class_method def self.contact_from(opts = {})
      return opts[:contact] if opts[:contact].is_a?(Meshtastic::Contact)

      Meshtastic::Contact.new(
        callsign: opts[:callsign].to_s,
        device_callsign: opts[:device_callsign].to_s
      )
    end

    private_class_method def self.group_from(opts = {})
      return opts[:group] if opts[:group].is_a?(Meshtastic::Group)

      Meshtastic::Group.new(team: opts[:team], role: opts[:role])
    end

    private_class_method def self.status_from(opts = {})
      return opts[:status] if opts[:status].is_a?(Meshtastic::Status)

      Meshtastic::Status.new(battery: opts[:battery].to_i)
    end

    private_class_method def self.pli_from(opts = {})
      return opts[:pli] if opts[:pli].is_a?(Meshtastic::PLI)

      pli = Meshtastic::PLI.new
      pli.latitude_i = scale_coord(value: opts[:lat]) if opts[:lat]
      pli.longitude_i = scale_coord(value: opts[:lon]) if opts[:lon]
      pli.altitude = opts[:altitude].to_i if opts[:altitude]
      pli.speed = opts[:speed].to_i if opts[:speed]
      pli.course = opts[:course].to_i if opts[:course]
      pli
    end

    private_class_method def self.chat_from(opts = {})
      return opts[:chat] if opts[:chat].is_a?(Meshtastic::GeoChat)

      Meshtastic::GeoChat.new(
        message: opts[:message].to_s,
        to: opts[:to].to_s,
        to_callsign: opts[:to_callsign].to_s
      )
    end
  end
end
