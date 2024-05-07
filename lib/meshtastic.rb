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
  #   from_id: 'optional - Source ID (Default: 0)',
  #   dest_id: 'optional - Destination ID (Default: 0xFFFFFFFF)',
  #   text: 'optional - Text Message (Default: SYN)',
  #   want_ack: 'optional - Want Acknowledgement (Default: false)',
  #   want_response: 'optional - Want Response (Default: false)',
  #   hop_limit: 'optional - Hop Limit (Default: 3)',
  #   on_response: 'optional - Callback on Response',
  #   psk: 'optional - Pre-Shared Key if Encrypted (Default: nil)'
  # )
  public_class_method def self.send_text(opts = {})
    # Send a text message to a node
    from_id = opts[:from_id].to_i
    dest_id = opts[:dest_id] ||= 0xFFFFFFFF
    text = opts[:text] ||= 'SYN'
    want_ack = opts[:want_ack] ||= false
    want_response = opts[:want_response] ||= false
    hop_limit = opts[:hop_limit] ||= 3
    on_response = opts[:on_response]
    psk = opts[:psk]
    
    # TODO: verify text length validity
    max_txt_len = Meshtastic::Constants::DATA_PAYLOAD_LEN
    raise "ERROR: Text Length > #{max_txt_len} Bytes" if text.length > max_txt_len

    port_num = Meshtastic::PortNum::TEXT_MESSAGE_APP

    data = Meshtastic::Data.new
    data.payload = text
    data.portnum = port_num
    data.want_response = want_response
    puts data.to_h

    send_data(
      from_id: from_id,
      dest_id: dest_id,
      data: data,
      want_ack: want_ack,
      want_response: want_response,
      hop_limit: hop_limit,
      port_num: port_num,
      on_response: on_response,
      psk: psk
    )
  rescue StandardError => e
    raise e
  end

  # Supported Method Parameters::
  # Meshtastic.send_data(
  #   from_id: 'optional - Source ID (Default: 0)',
  #   dest_id: 'optional - Destination ID (Default: 0xFFFFFFFF)',
  #   data: 'required - Data to Send',
  #   want_ack: 'optional - Want Acknowledgement (Default: false)',
  #   hop_limit: 'optional - Hop Limit (Default: 3)',
  #   port_num: 'optional - (Default: Meshtastic::PortNum::PRIVATE_APP)',
  #   psk: 'optional - Pre-Shared Key if Encrypted (Default: nil)'
  # )
  public_class_method def self.send_data(opts = {})
    # Send a text message to a node
    from_id = opts[:from_id].to_i
    dest_id = opts[:dest_id] ||= 0xFFFFFFFF
    data = opts[:data]
    want_ack = opts[:want_ack] ||= false
    hop_limit = opts[:hop_limit] ||= 3
    port_num = opts[:port_num] ||= Meshtastic::PortNum::PRIVATE_APP
    max_port_num = Meshtastic::PortNum::MAX
    raise "ERROR: Invalid port_num" unless port_num.positive? && port_num < max_port_num

    psk = opts[:psk]

    data_len = data.payload.length
    max_len = Meshtastic::Constants::DATA_PAYLOAD_LEN
    raise "ERROR: Data Length > #{max_len} Bytes" if data_len > max_len

    mesh_packet = Meshtastic::MeshPacket.new
    mesh_packet.decoded = data

    send_packet(
      mesh_packet: mesh_packet,
      from_id: from_id,
      dest_id: dest_id,
      want_ack: want_ack,
      hop_limit: hop_limit,
      psk: psk
    )
  rescue StandardError => e
    raise e
  end

  # Supported Method Parameters::
  # Meshtastic.send_packet(
  #   mesh_packet: 'required - Mesh Packet to Send',
  #   from_id: 'optional - Source ID (Default: 0)',
  #   dest_id: 'optional - Destination ID (Default: 0xFFFFFFFF)',
  #   want_ack: 'optional - Want Acknowledgement (Default: false)',
  #   hop_limit: 'optional - Hop Limit (Default: 3)',
  #   psk: 'optional - Pre-Shared Key if Encrypted (Default: nil)'
  # )
  public_class_method def self.send_packet(opts = {})
    mesh_packet = opts[:mesh_packet]
    from_id = opts[:from_id] ||= 0
    dest_id = opts[:dest_id] ||= 0xFFFFFFFF
    want_ack = opts[:want_ack] ||= false
    hop_limit = opts[:hop_limit] ||= 3
    psk = opts[:psk]

    # my_info = Meshtastic::FromRadio.my_info
    # wait_connected if dest_id != my_info.my_node_num && my_info.is_a(Meshtastic::Deviceonly::MyInfo)
    
    node_num = dest_id
    node_num_hex = dest_id.bytes.map { |b| b.to_s(16).rjust(2, '0') }.join if dest_id.is_a?(String)
    node_num = node_num_hex.to_i(16) if node_num_hex

    mesh_packet.from = from_id
    mesh_packet.to = node_num
    mesh_packet.want_ack = want_ack
    mesh_packet.hop_limit = hop_limit

    mesh_packet.id = generate_packet_id if mesh_packet.id.zero?

    if psk
      nonce_packet_id = [mesh_packet.id].pack('V').ljust(8, "\x00")
      nonce_from_node = [from_id].pack('V').ljust(8, "\x00")
      nonce = "#{nonce_packet_id}#{nonce_from_node}".b

      dec_psk = Base64.strict_decode64(psk)
      cipher = OpenSSL::Cipher.new('AES-128-CTR')
      cipher = OpenSSL::Cipher.new('AES-256-CTR') if dec_psk.length == 32
      cipher.encrypt
      cipher.key = dec_psk
      cipher.iv = nonce

      decrypted_payload = mesh_packet.decoded.to_s
      encrypted_payload = cipher.update(decrypted_payload) + cipher.final

      mesh_packet.encrypted = encrypted_payload
    end
    # puts mesh_packet.to_h

    # to_radio = Meshtastic::ToRadio.new
    # to_radio.packet = mesh_packet
    # send_to_radio(to_radio: to_radio)

    mesh_packet
  rescue StandardError => e
    raise e
  end

  # Supported Method Parameters::
  # packet_id = Meshtastic.generate_packet_id(
  #   last_packet_id: 'optional - Last Packet ID (Default: 0)'
  # )
  public_class_method def self.generate_packet_id(opts = {})
    last_packet_id = opts[:last_packet_id] ||= 0

    packet_id = last_packet_id + 1 if last_packet_id.positive?
    packet_id = rand(2**32) if last_packet_id.zero?

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
