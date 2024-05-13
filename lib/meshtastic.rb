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
  #   from: 'required - From ID (String or Integer)',
  #   to: 'optional - Destination ID (Default: 0xFFFFFFFF)',
  #   last_packet_id: 'optional - Last Packet ID (Default: 0)',
  #   via: 'optional - :radio || :mqtt (Default: :radio)',
  #   channel: 'optional - Channel ID (Default: 6)',
  #   text: 'optional - Text Message (Default: SYN)',
  #   want_ack: 'optional - Want Acknowledgement (Default: false)',
  #   want_response: 'optional - Want Response (Default: false)',
  #   hop_limit: 'optional - Hop Limit (Default: 3)',
  #   on_response: 'optional - Callback on Response',
  #   psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: "AQ==" })'
  # )
  public_class_method def self.send_text(opts = {})
    # Send a text message to a node
    from = opts[:from]
    from_hex = from.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if from.is_a?(String)
    from = from_hex.to_i(16) if from_hex
    raise 'ERROR: from parameter is required.' unless from

    to = opts[:to] ||= 0xFFFFFFFF
    to_hex = to.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if to.is_a?(String)
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
    data.payload = text
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
  #   from: 'required - From ID (String or Integer)',
  #   to: 'optional - Destination ID (Default: 0xFFFFFFFF)',
  #   last_packet_id: 'optional - Last Packet ID (Default: 0)',
  #   via: 'optional - :radio || :mqtt (Default: :radio)',
  #   channel: 'optional - Channel ID (Default: 0)',
  #   data: 'required - Data to Send',
  #   want_ack: 'optional - Want Acknowledgement (Default: false)',
  #   hop_limit: 'optional - Hop Limit (Default: 3)',
  #   port_num: 'optional - (Default: Meshtastic::PortNum::PRIVATE_APP)',
  #   psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: "AQ==" })'
  # )
  public_class_method def self.send_data(opts = {})
    # Send a text message to a node
    from = opts[:from]
    from_hex = from.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if from.is_a?(String)
    from = from_hex.to_i(16) if from_hex
    raise 'ERROR: from parameter is required.' unless from

    to = opts[:to] ||= 0xFFFFFFFF
    to_hex = to.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if to.is_a?(String)
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
  #   from: 'required - From ID (String or Integer)',
  #   to: 'optional - Destination ID (Default: 0xFFFFFFFF)',
  #   last_packet_id: 'optional - Last Packet ID (Default: 0)',
  #   via: 'optional - :radio || :mqtt (Default: :radio)',
  #   channel: 'optional - Channel ID (Default: 0)',
  #   want_ack: 'optional - Want Acknowledgement (Default: false)',
  #   hop_limit: 'optional - Hop Limit (Default: 3)',
  #   psks: 'optional - hash of :channel => psk key value pairs (default: { LongFast: "AQ==" })'
  # )
  public_class_method def self.send_packet(opts = {})
    mesh_packet = opts[:mesh_packet]
    from = opts[:from]
    from_hex = from.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if from.is_a?(String)
    from = from_hex.to_i(16) if from_hex
    raise 'ERROR: from parameter is required.' unless from

    to = opts[:to] ||= 0xFFFFFFFF
    to_hex = to.delete('!').bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if to.is_a?(String)
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
      nonce = "#{nonce_packet_id}#{nonce_from_node}".b

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

  # Author(s):: 0day Inc. <support@0dayinc.com>

  public_class_method def self.authors
    "AUTHOR(S):
      0day Inc. <support@0dayinc.com>
    "
  end

  # Display a List of Every Meshtastic Module

  public_class_method def self.help
    constants.sort
  end
end
