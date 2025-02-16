# frozen_string_literal: true

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  require 'base64'
  # Protocol Buffers for Meshtastic
  require 'meshtastic/admin_pb'
  require 'nanopb_pb'
  require 'meshtastic/apponly_pb'
  require 'meshtastic/atak_pb'
  require 'meshtastic/cannedmessages_pb'
  require 'meshtastic/channel_pb'
  require 'meshtastic/clientonly_pb'
  require 'meshtastic/config_pb'
  require 'meshtastic/connection_status_pb'
  require 'meshtastic/deviceonly_pb'
  require 'meshtastic/localonly_pb'
  require 'meshtastic/mesh_pb'
  require 'meshtastic/module_config_pb'
  require 'meshtastic/mqtt_pb'
  require 'meshtastic/paxcount_pb'
  require 'meshtastic/portnums_pb'
  require 'meshtastic/remote_hardware_pb'
  require 'meshtastic/rtttl_pb'
  require 'meshtastic/storeforward_pb'
  require 'meshtastic/telemetry_pb'
  require 'meshtastic/version'
  require 'meshtastic/xmodem_pb'
  require 'openssl'

  autoload :Admin, 'meshtastic/admin'
  autoload :Apponly, 'meshtastic/apponly'
  autoload :ATAK, 'meshtastic/atak'
  autoload :Cannedmessages, 'meshtastic/cannedmessages'
  autoload :Channel, 'meshtastic/channel'
  autoload :Clientonly, 'meshtastic/clientonly'
  autoload :Config, 'meshtastic/config'
  autoload :ConnectionStatus, 'meshtastic/connection_status'
  autoload :Deviceonly, 'meshtastic/deviceonly'
  autoload :Localonly, 'meshtastic/localonly'
  autoload :Mesh, 'meshtastic/mesh'
  autoload :ModuleConfig, 'meshtastic/module_config'
  autoload :MQTT, 'meshtastic/mqtt'
  autoload :Paxcount, 'meshtastic/paxcount'
  autoload :Portnums, 'meshtastic/portnums'
  autoload :RemoteHardware, 'meshtastic/remote_hardware'
  autoload :RTTTL, 'meshtastic/rtttl'
  autoload :Storeforward, 'meshtastic/storeforward'
  autoload :Telemetry, 'meshtastic/telemetry'
  autoload :Xmodem, 'meshtastic/xmodem'

  # Supported Method Parameters::
  # Meshtastic.send_text(
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
  public_class_method def self.send_text(opts = {})
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
  # Meshtastic.send_data(
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
  public_class_method def self.send_data(opts = {})
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
  # Meshtastic.send_packet(
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
  public_class_method def self.send_packet(opts = {})
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
      # Sending a to_radio message over mqtt
      # causes unpredictable behavior
      # (e.g. disconnecting node(s) from bluetooth)
      to_radio = Meshtastic::ToRadio.new
      to_radio.packet = mesh_packet
      send_to_radio(to_radio: to_radio)
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
  # packet_id = Meshtastic.generate_packet_id(
  #   last_packet_id: 'optional - Last Packet ID (Default: 0)'
  # )
  public_class_method def self.generate_packet_id(opts = {})
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

  public_class_method def self.get_cipher_keys(opts = {})
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
  # Meshtastic.send_to_radio(
  #   to_radio: 'required - ToRadio Message to Send'
  # )
  public_class_method def self.send_to_radio(opts = {})
    to_radio = opts[:to_radio]

    raise 'ERROR: Invalid ToRadio Message' unless to_radio.is_a?(Meshtastic::ToRadio)

    to_radio.to_proto
  rescue StandardError => e
    raise e
  end

  # Supported Method Parameters::
  # Meshtastic.send_to_mqtt(
  #   service_envelope: 'required - ServiceEnvelope Message to Send'
  # )
  public_class_method def self.send_to_mqtt(opts = {})
    service_envelope = opts[:service_envelope]

    raise 'ERROR: Invalid ServiceEnvelope Message' unless service_envelope.is_a?(Meshtastic::ServiceEnvelope)

    service_envelope.to_proto
  rescue StandardError => e
    raise e
  end

  # Supported Method Parameters::
  # Meshtastic.gps_search(
  #   lat: 'required - latitude float (e.g. 37.7749)',
  #   lon: 'required - longitude float (e.g. -122.4194)'
  # )
  public_class_method def self.gps_search(opts = {})
    lat = opts[:lat]
    lon = opts[:lon]

    raise 'ERROR: Latitude and Longitude are required' unless lat && lon

    gps_arr = [lat.to_f, lon.to_f]

    Geocoder.search(gps_arr).first.data
  rescue StandardError => e
    raise e
  end

  # Supported Method Parameters::
  # Meshtastic::MQQT.decode_payload(
  #   payload: 'required - payload to recursively decode',
  #   msg_type: 'required - message type (e.g. :TEXT_MESSAGE_APP)',
  #   gps_metadata: 'optional - include GPS metadata in output (default: false)',
  # )

  public_class_method def self.decode_payload(opts = {})
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

  public_class_method def self.authors
    "AUTHOR(S):
      0day Inc. <support@0dayinc.com>
    "
  end

  # Display a List of Every Meshtastic Module

  public_class_method def self.help
    puts "USAGE:
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

      #{self}.generate_packet_id(
        last_packet_id: 'optional - Last Packet ID (Default: 0)'
      )

      #{self}.get_cipher_keys(
        psks: 'required - hash of channel / pre-shared key value pairs'
      )

      #{self}.send_to_radio(
        to_radio: 'required - ToRadio Message to Send'
      )

      #{self}.send_to_mqtt(
        service_envelope: 'required - ServiceEnvelope Message to Send'
      )

      #{self}.gps_search(
        lat: 'required - latitude float (e.g. 37.7749)',
        lon: 'required - longitude float (e.g. -122.4194)'
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
