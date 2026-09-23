# frozen_string_literal: true

require 'zlib'
require 'json'
require_relative 'tak_codec_fixtures'

# Independent wire fixtures shared by real UART, stream, GATT and MQTT adapters.
module PayloadFixtures
  def payload_cases
    schemas = {
      REMOTE_HARDWARE_APP: Meshtastic::HardwareMessage.new(gpio_mask: 3),
      POSITION_APP: Meshtastic::Position.new(altitude: 42),
      NODEINFO_APP: Meshtastic::User.new(long_name: 'fixture'),
      ROUTING_APP: Meshtastic::Routing.new(error_reason: :NO_ROUTE),
      ADMIN_APP: Meshtastic::AdminMessage.new(get_owner_request: true),
      WAYPOINT_APP: Meshtastic::Waypoint.new(name: 'fixture'),
      KEY_VERIFICATION_APP: Meshtastic::KeyVerification.new(nonce: 42),
      REMOTE_SHELL_APP: Meshtastic::RemoteShell.new(payload: "\x00\xff".b),
      PAXCOUNTER_APP: Meshtastic::Paxcount.new(wifi: 42),
      STORE_FORWARD_PLUSPLUS_APP: Meshtastic::StoreForwardPlusPlus.new(message: "\x00\xff".b),
      NODE_STATUS_APP: Meshtastic::StatusMessage.new(status: 'fixture'),
      MESH_BEACON_APP: Meshtastic::MeshBeacon.new(message: 'fixture'),
      STORE_FORWARD_APP: Meshtastic::StoreAndForward.new(text: 'fixture'),
      TELEMETRY_APP: Meshtastic::Telemetry.new(device_metrics: Meshtastic::DeviceMetrics.new(battery_level: 42)),
      SIMULATOR_APP: Meshtastic::Compressed.new(portnum: :TEXT_MESSAGE_APP, data: 'fixture'),
      TRACEROUTE_APP: Meshtastic::RouteDiscovery.new(route: [42]),
      NEIGHBORINFO_APP: Meshtastic::NeighborInfo.new(node_id: 42),
      ATAK_PLUGIN: Meshtastic::TAKPacket.new(detail: 'fixture'),
      MAP_REPORT_APP: Meshtastic::MapReport.new(long_name: 'fixture'),
      POWERSTRESS_APP: Meshtastic::PowerStressMessage.new(num_seconds: 2.5),
      LORAWAN_BRIDGE: Meshtastic::LoRaWANBridge.new(uplink: Meshtastic::LoRaWANBridge::Uplink.new(payload: "\x00\xff".b)),
      ATAK_PLUGIN_V2: Meshtastic::TAKPacketV2.new(callsign: 'fixture')
    }
    cases = schemas.flat_map do |port, proto|
      wire = port == :ATAK_PLUGIN_V2 ? "\xff".b + proto.to_proto : proto.to_proto
      malformed = port == :ATAK_PLUGIN_V2 ? "\xff\xff".b : "\xff".b
      [[port, wire, proto.to_h], [port, ''.b, {}], [port, malformed, malformed]]
    end
    %i[TEXT_MESSAGE_APP DETECTION_SENSOR_APP ALERT_APP REPLY_APP RANGE_TEST_APP].each do |port|
      cases << [port, "\x08\x01hi", "\x08\x01hi"]
      cases << [port, ''.b, '']
    end
    %i[UNKNOWN_APP TEXT_MESSAGE_COMPRESSED_APP PAGING_APP SERIAL_APP
       GROUPALARM_APP PRIVATE_APP MAX].each do |port|
      cases << [port, "\x08\x01\xff".b, "\x08\x01\xff".b]
    end
    cases << [:TEXT_MESSAGE_COMPRESSED_APP, ['8767c714bdeb7c74'].pack('H*'), 'Hello world']
    cases << [:ATAK_PLUGIN, ['080112070a05804f1e3b49'].pack('H*'), { contact: { callsign: 'ALPHA' } }]
    TAK_CODEC_FIXTURES.each do |_name, wire, proto|
      expected = Meshtastic::TAKPacketV2.decode([proto].pack('H*')).to_h
      expected[:latitude] = expected[:latitude_i] * 0.0000001 if expected.key?(:latitude_i)
      expected[:longitude] = expected[:longitude_i] * 0.0000001 if expected.key?(:longitude_i)
      cases << [:ATAK_PLUGIN_V2, [wire].pack('H*'), expected]
    end
    cases.concat(binary_payload_cases)
    cases.concat(reticulum_payload_cases)
    cases << [51, "\x08\x01".b, "\x08\x01".b]
    cases << [51, ''.b, nil]
    cases
  end

  def reticulum_payload_cases
    fixtures = JSON.parse(File.read(File.join(__dir__, 'reticulum_fixtures.json')))
    raw = [fixtures.fetch('single_hex')].pack('H*')
    expected = { format: :reticulum_fragment, message_index: 0, position: -1, index: 1,
                 count: 1, final: true, complete: true, raw: raw, body: "\x00\xffRNS opaque".b }
    request = [fixtures.fetch('request_hex')].pack('H*')
    cases = [[:RETICULUM_TUNNEL_APP, raw, expected],
             [:RETICULUM_TUNNEL_APP, request, { format: :reticulum_request, message_index: 255,
                                              position: 2, index: 2, raw: request, complete: false }]]
    ["\x01\x00\xff".b, "REQ\xff".b, "\xff".b].each do |malformed|
      cases << [:RETICULUM_TUNNEL_APP, malformed, malformed]
    end
    wrapper = Meshtastic::Compressed.new(portnum: :RETICULUM_TUNNEL_APP, data: raw).to_proto
    cases << [:SIMULATOR_APP, wrapper, { portnum: :RETICULUM_TUNNEL_APP, data: expected }]
    cases
  end

  def binary_payload_cases
    samples = [
      [:CAYENNE_APP, '0167ffd7', { portnum: 77, format: :cayenne_lpp, status: :decoded,
                                   records: [{ channel: 1, type: 103, name: :temperature, value: -4.1, unit: 'C' }] }],
      [:AUDIO_APP, 'c0dec2000011223344556677', { portnum: 9, format: :codec2, status: :decoded, mode: 0,
                                                 bitrate: 3200, bits_per_frame: 64, bytes_per_frame: 8, samples_per_frame: 160,
                                                 sample_rate: 8000, pcm_decoded: false,
                                                 encoded: ['0011223344556677'].pack('H*'), frames: [['0011223344556677'].pack('H*')] }],
      [:IP_TUNNEL_APP, '45000015006f00007b012b770a0000010a00000200',
       { portnum: 33, format: :ip, status: :decoded, version: 4, header_length: 20, total_length: 21,
         dscp_ecn: 0, identification: 111, flags: 0, fragment_offset: 0, ttl: 123, protocol: 1, checksum: 11_127,
         header_checksum_valid: true, source: '10.0.0.1', destination: '10.0.0.2', options: ''.b, body: "\0".b }],
      [:LORA_OTA_APP, '0307d204c8000004', { portnum: 79, format: :ota_common, status: :decoded, type: :block,
                                            type_id: 3, session: 7, index: 1234, offset: 200, total: 1024,
                                            body: ''.b, signature_verified: false }],
      [:ZPS_APP, '01000000000000000000000000000000', { portnum: 68, format: :opaque, status: :unsupported,
                                                       error: 'ZPS has no stable port-68 schema; select zps_profile: :esp32_legacy only for that experimental dialect' }]
    ].map { |port, hex, expected| [port, [hex].pack('H*'), expected.merge(raw: [hex].pack('H*'))] }
    { AUDIO_APP: [9, 'Codec2 needs C0 DE C2 magic and mode byte'],
      IP_TUNNEL_APP: [33, 'truncated IPv4 header'], CAYENNE_APP: [77, 'truncated Cayenne channel/type'],
      LORA_OTA_APP: [79, 'OTA frame must contain 8..233 bytes'] }.each do |port, (id, error)|
      samples << [port, 'A'.b, { portnum: id, raw: 'A'.b, status: :malformed, error: error }]
    end
    samples << [:ATAK_FORWARDER, "\x01ATAKBCAST,mesh,uid,ALPHA,1".b,
                { format: :forwarder_discovery, mesh_id: 'mesh', uid: 'uid', callsign: 'ALPHA', initial: true }]
    samples << [:ATAK_FORWARDER, "\x02first".b, { format: :forwarder_fragment, index: 0, count: 2, body: 'first'.b }]
    event = { format: :libcotshrink_protobuf, compression: :none, protobuf: { uid: 'test' },
              event: { uid: 'test', type: 'a-f-G-U-C', lat: 0.0, lon: 0.0, ce: 0, le: 0, hae: -900.0,
                       time_offset_seconds: 0, stale_after_seconds: 0, how: 'h-e' },
              extensions: { how: 'h-e', geopointsrc: 'DTED0', altsrc: 'DTED0', role: 'Team Member', battery: 0,
                            readiness: false, labels_on: false, height_unit: 0, ce_human_input: false, tog: false,
                            route_planning_method: 'Infil', route_method: 'Driving', route_type: 'On Foot',
                            route_route_type: 'Primary', route_order: 'Ascending Check Points', route_stroke: 0 } }
    samples << [:ATAK_FORWARDER, "\x01\x0a\x04test".b, event]
    samples << [:ATAK_FORWARDER, "\x01".b + Zlib.gzip("\x0a\x04test".b), event.merge(compression: :gzip)]
    samples << [:ATAK_FORWARDER, "\x01$EXI".b, "\x01$EXI".b]
    samples << [:ATAK_FORWARDER, "\x00".b, "\x00".b]
    samples
  end

  def payload_radio(port, bytes)
    Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(
      from: 123, id: 42, decoded: Meshtastic::Data.new(portnum: port, payload: bytes)
    ))
  end
end
