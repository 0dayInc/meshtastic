# frozen_string_literal: true

require 'meshtastic/mesh_pb'

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  class MeshInterface
    attr_accessor :acknowledgment,
                  :config_id,
                  :current_packet_id,
                  :debug_out,
                  :got_response,
                  :failure,
                  :heartbeat_timer,
                  :is_connected,
                  :is_proto,
                  :local_channels,
                  :mask,
                  :metadata,
                  :my_info,
                  :no_nodes,
                  :nodes,
                  :nodes_by_num,
                  :queue,
                  :queue_status,
                  :response_handlers,
                  :timeout

    def initialize(opts = {})
      @acknowledgment = Meshtastic::Util::Acknowledgement.new

      @current_packet_id = generate_packet_id

      @debug_out = opts[:debug_out]

      @failure = nil

      @got_response = false

      @heartbeat_timer = nil

      @is_connected = true if opts[:is_connected]
      @is_connected = false unless opts[:is_connected] # TODO: threading.Event = threading.Event()

      @is_proto = true if opts[:is_proto]
      @is_proto = false unless opts[:is_proto]

      @local_channels = nil

      @mask = nil

      @metadata = Meshtastic::DeviceMetadata.new

      @my_info = Meshtastic::MyNodeInfo

      @no_nodes = true if opts[:no_nodes]
      @no_nodes = false unless opts[:no_nodes]

      @nodes = { nodes: {} }

      @nodes_by_num = {}

      @queue = {}
      @queue_status = Meshtastic::QueueStatus.new

      @response_handlers = {}

      @timeout = Meshtastic::Util::Timeout.new

      @config_id = NODELESS_WANT_CONFIG_ID if no_nodes
      @config_id = nil unless no_nodes
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # packet_id = Meshtastic.generate_packet_id(
    #   last_packet_id: 'optional - Last Packet ID (Default: 0)'
    # )
    def generate_packet_id(opts = {})
      last_packet_id = opts[:last_packet_id] ||= 0
      last_packet_id = 0 if last_packet_id.negative?

      packet_id = Random.rand(0xffffffff) if last_packet_id.zero?
      packet_id = (last_packet_id + 1) & 0xffffffff if last_packet_id.positive?

      packet_id
    end

    # Supported Method Parameters::
    # Meshtastic.get_cipher_keys(
    #   psks: 'required - hash of channel / pre-shared key value pairs'
    # )

    def get_cipher_keys(opts = {})
      psks = opts[:psks]

      psks.each_key do |key|
        psk = psks[key]
        padded_psk = psk.ljust(psk.length + ((4 - (psk.length % 4)) % 4), '=')
        replaced_psk = padded_psk.gsub('-', '+').gsub('_', '/')
        psks[key] = replaced_psk
      end

      psks
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic.gps_search(
    #   lat: 'required - latitude float (e.g. 37.7749)',
    #   lon: 'required - longitude float (e.g. -122.4194)'
    # )
    def gps_search(opts = {})
      lat = opts[:lat]
      lon = opts[:lon]

      raise 'ERROR: Latitude and Longitude are required' unless lat && lon

      gps_arr = [lat.to_f, lon.to_f]

      Geocoder.search(gps_arr).first.data
    rescue StandardError => e
      raise e
    end

    # Meshtastic::MeshInterface.send_to_radio(
    #   payload: 'required - ToRadio Message to Send'
    # )
    def send_to_radio(opts = {})
      payload = opts[:payload]

      raise 'ERROR: Invalid ToRadio Message' unless payload.is_a?(Meshtastic::ToRadio)

      payload.to_proto
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::MeshInterface.send_to_mqtt(
    #   service_envelope: 'required - ServiceEnvelope Message to Send'
    # )
    def send_to_mqtt(opts = {})
      service_envelope = opts[:service_envelope]

      raise 'ERROR: Invalid ServiceEnvelope Message' unless service_envelope.is_a?(Meshtastic::ServiceEnvelope)

      service_envelope.to_proto
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::Mesh.start_config(
    # )
    def start_config
      @my_info = nil
      @nodes = {}
      @nodes_by_num = {}
      @local_channels = []

      to_radio_start_config = Meshtastic::ToRadio.new
      if @config_id.nil? || !@no_nodes
        @config_id = Random.rand(0xFFFFFFFF)
        @config_id += 1 if @config_id == NODELESS_WANT_CONFIG_ID
      end
      to_radio_start_config.want_config_id = @config_id
      send_to_radio(payload: to_radio_start_config)
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::Mesh.my_node_info
    def my_node_info
      mni = Meshtastic::MyNodeInfo.new
      mni.to_h
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::MeshInterface.send_packet(
    #   mesh_packet: 'required - Mesh Packet to Send',
    #   from: 'required - From ID (String or Integer) (Default: "!00000b0b")',
    #   to: 'optional - Destination ID (Default: "!ffffffff")',
    #   last_packet_id: 'optional - Last Packet ID (Default: 0)',
    #   via: 'optional - :radio || :mqtt (Default: :radio)',
    #   channel: 'optional - Channel (Default: 0)',
    #   want_ack: 'optional - Want Acknowledgement (Default: false)',
    #   hop_limit: 'optional - Hop Limit (Default: 3)',
    #   psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: "AQ==" })'
    # )
    def send_packet(opts = {})
      mesh_packet = opts[:mesh_packet]
      from = opts[:from] ||= '!00000b0b'
      # from_hex = from.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if from.is_a?(String)
      from_hex = from.delete('!') if from.is_a?(String)
      from = from_hex.to_i(16) if from_hex
      raise 'ERROR: from parameter is required.' unless from

      to = opts[:to] ||= '!ffffffff'
      # to_hex = to.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if to.is_a?(String)
      to_hex = to.delete('!') if to.is_a?(String)
      to = to_hex.to_i(16) if to_hex

      last_packet_id = opts[:last_packet_id] ||= 0
      via = opts[:via] ||= :radio
      channel = opts[:channel] ||= 0
      want_ack = opts[:want_ack] ||= false
      hop_limit = opts[:hop_limit] ||= 3

      public_psk = '1PG7OiApB1nwvP+rz05pAQ=='
      psks = opts[:psks] ||= { LongFast: public_psk }
      raise 'ERROR: psks parameter must be a hash of :channel => psk key value pairs' unless psks.is_a?(Hash)

      psks[:LongFast] = public_psk if psks[:LongFast] == 'AQ=='

      # my_info = Meshtastic::FromRadio.my_info
      # wait_connected if to != my_info.my_node_num && my_info.is_a(Meshtastic::Deviceonly::MyInfo)

      mesh_packet.from = from
      mesh_packet.to = to
      mesh_packet.channel = channel
      mesh_packet.want_ack = want_ack
      mesh_packet.hop_limit = hop_limit
      mesh_packet.id = generate_packet_id(last_packet_id: last_packet_id)

      if psks
        nonce_packet_id = [mesh_packet.id].pack('V').ljust(8, "\x00")
        nonce_from_node = [from].pack('V').ljust(8, "\x00")
        nonce = "#{nonce_packet_id}#{nonce_from_node}"

        psk = psks[psks.keys.first]
        dec_psk = Base64.strict_decode64(psk)
        cipher = OpenSSL::Cipher.new('AES-128-CTR')
        cipher = OpenSSL::Cipher.new('AES-256-CTR') if dec_psk.length == 32
        cipher.encrypt
        cipher.key = dec_psk
        cipher.iv = nonce

        decrypted_payload = mesh_packet.decoded.to_proto
        encrypted_payload = cipher.update(decrypted_payload) + cipher.final

        mesh_packet.encrypted = encrypted_payload
      end
      # puts mesh_packet.to_h

      # puts "Sending Packet via: #{via}"
      case via
      when :radio
        payload = Meshtastic::ToRadio.new
        payload.packet = mesh_packet
        send_to_radio(payload: payload)
      when :mqtt
        service_envelope = Meshtastic::ServiceEnvelope.new
        service_envelope.packet = mesh_packet
        # TODO: Add support for multiple PSKs by accepting channel_id
        service_envelope.channel_id = psks.keys.first
        service_envelope.gateway_id = "!#{from.to_s(16).downcase}"
        send_to_mqtt(service_envelope: service_envelope)
      else
        raise "ERROR: Invalid via parameter: #{via}"
      end
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::MeshInterface.send_data(
    #   from: 'required - From ID (String or Integer) (Default: "!00000b0b")',
    #   to: 'optional - Destination ID (Default: "!ffffffff")',
    #   last_packet_id: 'optional - Last Packet ID (Default: 0)',
    #   via: 'optional - :radio || :mqtt (Default: :radio)',
    #   channel: 'optional - Channel (Default: 0)',
    #   data: 'required - Data to Send',
    #   want_ack: 'optional - Want Acknowledgement (Default: false)',
    #   hop_limit: 'optional - Hop Limit (Default: 3)',
    #   port_num: 'optional - (Default: Meshtastic::PortNum::PRIVATE_APP)',
    #   psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: "AQ==" })'
    # )
    def send_data(opts = {})
      # Send a text message to a node
      from = opts[:from] ||= '!00000b0b'
      # from_hex = from.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if from.is_a?(String)
      from_hex = from.delete('!') if from.is_a?(String)
      from = from_hex.to_i(16) if from_hex
      raise 'ERROR: from parameter is required.' unless from

      to = opts[:to] ||= '!ffffffff'
      # to_hex = to.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if to.is_a?(String)
      to_hex = to.delete('!') if to.is_a?(String)
      to = to_hex.to_i(16) if to_hex

      last_packet_id = opts[:last_packet_id] ||= 0
      via = opts[:via] ||= :radio
      channel = opts[:channel] ||= 0
      data = opts[:data]
      want_ack = opts[:want_ack] ||= false
      hop_limit = opts[:hop_limit] ||= 3
      port_num = opts[:port_num] ||= Meshtastic::PortNum::PRIVATE_APP
      max_port_num = Meshtastic::PortNum::MAX
      raise "ERROR: Invalid port_num" unless port_num.positive? && port_num < max_port_num

      public_psk =  '1PG7OiApB1nwvP+rz05pAQ=='
      psks = opts[:psks] ||= { LongFast: public_psk }
      raise 'ERROR: psks parameter must be a hash of :channel => psk key value pairs' unless psks.is_a?(Hash)

      psks[:LongFast] = public_psk if psks[:LongFast] == 'AQ=='

      data_len = data.payload.length
      max_len = Meshtastic::Constants::DATA_PAYLOAD_LEN
      raise "ERROR: Data Length > #{max_len} Bytes" if data_len > max_len

      mesh_packet = Meshtastic::MeshPacket.new
      mesh_packet.decoded = data

      send_packet(
        mesh_packet: mesh_packet,
        from: from,
        to: to,
        last_packet_id: last_packet_id,
        via: via,
        channel: channel,
        want_ack: want_ack,
        hop_limit: hop_limit,
        psks: psks
      )
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::MeshInterface.send_text(
    #   from: 'required - From ID (String or Integer) (Default: "!00000b0b")',
    #   to: 'optional - Destination ID (Default: "!ffffffff")',
    #   last_packet_id: 'optional - Last Packet ID (Default: 0)',
    #   via: 'optional - :radio || :mqtt (Default: :radio)',
    #   channel: 'optional - Channel (Default: 6)',
    #   text: 'optional - Text Message (Default: SYN)',
    #   want_ack: 'optional - Want Acknowledgement (Default: false)',
    #   want_response: 'optional - Want Response (Default: false)',
    #   hop_limit: 'optional - Hop Limit (Default: 3)',
    #   on_response: 'optional - Callback on Response',
    #   psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: "AQ==" })'
    # )
    def send_text(opts = {})
      # Send a text message to a node
      from = opts[:from] ||= '!00000b0b'
      # from_hex = from.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if from.is_a?(String)
      from_hex = from.delete('!') if from.is_a?(String)
      from = from_hex.to_i(16) if from_hex
      raise 'ERROR: from parameter is required.' unless from

      to = opts[:to] ||= '!ffffffff'
      # to_hex = to.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if to.is_a?(String)
      to_hex = to.delete('!') if to.is_a?(String)
      to = to_hex.to_i(16) if to_hex

      last_packet_id = opts[:last_packet_id] ||= 0
      via = opts[:via] ||= :radio
      channel = opts[:channel] ||= 6
      text = opts[:text] ||= 'SYN'
      want_ack = opts[:want_ack] ||= false
      want_response = opts[:want_response] ||= false
      hop_limit = opts[:hop_limit] ||= 3
      on_response = opts[:on_response]

      public_psk =  '1PG7OiApB1nwvP+rz05pAQ=='
      psks = opts[:psks] ||= { LongFast: public_psk }
      raise 'ERROR: psks parameter must be a hash of :channel => psk key value pairs' unless psks.is_a?(Hash)

      psks[:LongFast] = public_psk if psks[:LongFast] == 'AQ=='

      # TODO: verify text length validity
      max_txt_len = Meshtastic::Constants::DATA_PAYLOAD_LEN
      raise "ERROR: Text Length > #{max_txt_len} Bytes" if text.length > max_txt_len

      port_num = Meshtastic::PortNum::TEXT_MESSAGE_APP

      data = Meshtastic::Data.new
      data.payload = text.force_encoding('ASCII-8BIT')
      data.portnum = port_num
      data.want_response = want_response
      # puts data.to_h

      send_data(
        from: from,
        to: to,
        last_packet_id: last_packet_id,
        via: via,
        channel: channel,
        data: data,
        want_ack: want_ack,
        want_response: want_response,
        hop_limit: hop_limit,
        port_num: port_num,
        on_response: on_response,
        psks: psks
      )
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::MQQT.decode_payload(
    #   payload: 'required - payload to recursively decode',
    #   msg_type: 'required - message type (e.g. :TEXT_MESSAGE_APP)',
    #   gps_metadata: 'optional - include GPS metadata in output (default: false)',
    # )

    def decode_payload(opts = {})
      payload = opts[:payload]
      msg_type = opts[:msg_type]
      gps_metadata = opts[:gps_metadata]

      case msg_type
      when :ADMIN_APP
        decoder = Meshtastic::AdminMessage
      when :ATAK_FORWARDER, :ATAK_PLUGIN
        decoder = Meshtastic::TAKPacket
        # when :AUDIO_APP
        # decoder = Meshtastic::Audio
      when :DETECTION_SENSOR_APP
        decoder = Meshtastic::DeviceState
        # when :IP_TUNNEL_APP
        # decoder = Meshtastic::IpTunnel
      when :MAP_REPORT_APP
        decoder = Meshtastic::MapReport
        # when :MAX
        # decoder = Meshtastic::Max
      when :NEIGHBORINFO_APP
        decoder = Meshtastic::NeighborInfo
      when :NODEINFO_APP
        decoder = Meshtastic::User
      when :PAXCOUNTER_APP
        decoder = Meshtastic::Paxcount
      when :POSITION_APP
        decoder = Meshtastic::Position
        # when :PRIVATE_APP
        # decoder = Meshtastic::Private
      when :RANGE_TEST_APP
        # Unsure if this is the correct protobuf object
        decoder = Meshtastic::FromRadio
      when :REMOTE_HARDWARE_APP
        decoder = Meshtastic::HardwareMessage
        # when :REPLY_APP
        # decoder = Meshtastic::Reply
      when :ROUTING_APP
        decoder = Meshtastic::Routing
      when :SERIAL_APP
        decoder = Meshtastic::SerialConnectionStatus
      when :SIMULATOR_APP
        decoder = Meshtastic::Compressed
      when :STORE_FORWARD_APP
        decoder = Meshtastic::StoreAndForward
      when :TELEMETRY_APP
        decoder = Meshtastic::Telemetry
      when :TEXT_MESSAGE_APP, :UNKNOWN_APP
        decoder = Meshtastic::Data
      when :TRACEROUTE_APP
        decoder = Meshtastic::RouteDiscovery
      when :WAYPOINT_APP
        decoder = Meshtastic::Waypoint
        # when :ZPS_APP
        # decoder = Meshtastic::Zps
      else
        puts "WARNING: Can't decode\n#{payload.inspect}\nw/ portnum: #{msg_type}"
        return payload
      end

      payload = decoder.decode(payload).to_h

      if payload.keys.include?(:latitude_i)
        lat = payload[:latitude_i] * 0.0000001
        payload[:latitude] = lat
      end

      if payload.keys.include?(:longitude_i)
        lon = payload[:longitude_i] * 0.0000001
        payload[:longitude] = lon
      end

      if payload.keys.include?(:macaddr)
        mac_raw = payload[:macaddr]
        mac_hex_arr = mac_raw.bytes.map { |byte| byte.to_s(16).rjust(2, '0') }
        mac_hex_str = mac_hex_arr.join(':')
        payload[:macaddr] = mac_hex_str
      end

      if payload.keys.include?(:public_key)
        public_key_raw = payload[:public_key]
        payload[:public_key] = Base64.strict_encode64(public_key_raw)
      end

      if payload.keys.include?(:time)
        time_int = payload[:time]
        if time_int.is_a?(Integer)
          time_utc = Time.at(time_int).utc.to_s
          payload[:time_utc] = time_utc
        end
      end

      if gps_metadata && payload[:latitude] && payload[:longitude]
        lat = payload[:latitude]
        lon = payload[:longitude]
        unless lat.zero? && lon.zero?
          gps_search_resp = gps_search(lat: lat, lon: lon)
          payload[:gps_metadata] = gps_search_resp
        end
      end

      payload
    rescue Encoding::CompatibilityError,
           Google::Protobuf::ParseError
      payload
    rescue StandardError => e
      raise e
    end

    # Author(s):: 0day Inc. <support@0dayinc.com>

    def authors
      "AUTHOR(S):
        0day Inc. <support@0dayinc.com>
      "
    end

    # Display Usage for this Module

    def help
      puts "USAGE:
        #{self}.send_to_radio(
          payload: 'required - ToRadio Message to Send'
        )

        #{self}.send_to_mqtt(
          service_envelope: 'required - ServiceEnvelope Message to Send'
        )

        #{self}.start_config

        #{self}.my_node_info

        #{self}.send_packet(
          mesh_packet: 'required - Mesh Packet to Send',
          from: 'required - From ID (String or Integer) (Default: \"!00000b0b\")',
          to: 'optional - Destination ID (Default: \"!ffffffff\")',
          last_packet_id: 'optional - Last Packet ID (Default: 0)',
          via: 'optional - :radio || :mqtt (Default: :radio)',
          channel: 'optional - Channel (Default: 0)',
          want_ack: 'optional - Want Acknowledgement (Default: false)',
          hop_limit: 'optional - Hop Limit (Default: 3)',
          psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: \"AQ==\" })'
        )

        #{self}.send_data(
          from: 'required - From ID (String or Integer) (Default: \"!00000b0b\")',
          to: 'optional - Destination ID (Default: \"!ffffffff\")',
          last_packet_id: 'optional - Last Packet ID (Default: 0)',
          via: 'optional - :radio || :mqtt (Default: :radio)',
          channel: 'optional - Channel (Default: 0)',
          data: 'required - Data to Send',
          want_ack: 'optional - Want Acknowledgement (Default: false)',
          hop_limit: 'optional - Hop Limit (Default: 3)',
          port_num: 'optional - (Default: Meshtastic::PortNum::PRIVATE_APP)',
          psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: \"AQ==\" })'
        )

        #{self}.send_text(
          from: 'required - From ID (String or Integer) (Default: \"!00000b0b\")',
          to: 'optional - Destination ID (Default: \"!ffffffff\")',
          last_packet_id: 'optional - Last Packet ID (Default: 0)',
          via: 'optional - :radio || :mqtt (Default: :radio)',
          channel: 'optional - Channel (Default: 6)',
          text: 'optional - Text Message (Default: SYN)',
          want_ack: 'optional - Want Acknowledgement (Default: false)',
          want_response: 'optional - Want Response (Default: false)',
          hop_limit: 'optional - Hop Limit (Default: 3)',
          on_response: 'optional - Callback on Response',
          psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: \"AQ==\" })'
        )

        #{self}.decode_payload(
          payload: 'required - payload to recursively decode',
          msg_type: 'required - message type (e.g. :TEXT_MESSAGE_APP)',
          gps_metadata: 'optional - include GPS metadata in output (default: false)',
        )

        #{self}.authors
      "
    end
  end
end
