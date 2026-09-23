# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/payload_fixtures'

describe Meshtastic::MeshInterface do
  include PayloadFixtures

  it 'inventories every bundled port exactly once and exercises each through transport fixtures' do
    ports = described_class::PROTOBUF_PAYLOADS.keys + described_class::TEXT_PAYLOADS + described_class::BINARY_PAYLOADS + described_class::RAW_PAYLOADS + [:PRIVATE_APP]
    expect(ports.sort).to eq(Meshtastic::PortNum.constants.sort)
    expect(payload_cases.map(&:first).grep(Symbol).uniq.sort).to eq(ports.sort)
    doc = File.read(File.expand_path('../../../documentation/mesh-interface.md', __dir__))
    rows = doc.scan(/^\| (\d+) \| ([A-Z0-9_]+) \|/).to_h.transform_values(&:to_sym)
    expect(rows).to eq(ports.to_h { |port| [Meshtastic::PortNum.resolve(port).to_s, port] })
  end

  it 'decodes default proto3 application messages even when Data omits payload bytes' do
    data = Meshtastic::Data.new(portnum: :ROUTING_APP).to_h
    expect(described_class.new.decode_payload(payload: data[:payload], msg_type: data[:portnum])).to eq({})
    expect(described_class.new.decode_payload(payload: ''.b, msg_type: 5)).to eq({})
  end

  {
    REMOTE_HARDWARE_APP: :HardwareMessage, POSITION_APP: :Position, NODEINFO_APP: :User,
    ROUTING_APP: :Routing, ADMIN_APP: :AdminMessage, WAYPOINT_APP: :Waypoint,
    KEY_VERIFICATION_APP: :KeyVerification, REMOTE_SHELL_APP: :RemoteShell,
    PAXCOUNTER_APP: :Paxcount, STORE_FORWARD_PLUSPLUS_APP: :StoreForwardPlusPlus,
    NODE_STATUS_APP: :StatusMessage, MESH_BEACON_APP: :MeshBeacon,
    STORE_FORWARD_APP: :StoreAndForward, TELEMETRY_APP: :Telemetry,
    SIMULATOR_APP: :Compressed, TRACEROUTE_APP: :RouteDiscovery,
    NEIGHBORINFO_APP: :NeighborInfo, ATAK_PLUGIN: :TAKPacket, MAP_REPORT_APP: :MapReport,
    POWERSTRESS_APP: :PowerStressMessage, LORAWAN_BRIDGE: :LoRaWANBridge, ATAK_PLUGIN_V2: :TAKPacketV2
  }.each do |port, schema|
    it "decodes empty #{port} using #{schema}, with symbolic and numeric portnums" do
      [port, Meshtastic::PortNum.resolve(port)].each do |portnum|
        [nil, ''.b].each do |bytes|
          expect(described_class.new.decode_payload(payload: bytes, msg_type: portnum)).to eq(Meshtastic.const_get(schema).new.to_h)
        end
      end
    end
  end
end

describe Meshtastic::MeshInterface, 'simulator and text decoding' do
  it 'dispatches nested simulator data through its contained application port' do
    position = Meshtastic::Position.new(latitude_i: 10_000_000).to_proto
    inner = Meshtastic::Compressed.new(portnum: :POSITION_APP, data: position).to_proto
    outer = Meshtastic::Compressed.new(portnum: :SIMULATOR_APP, data: inner).to_proto
    result = described_class.new.decode_payload(payload: outer, msg_type: 69)
    expect(result.dig(:data, :data)).to include(latitude_i: 10_000_000, latitude: 1.0)
  end

  it 'bounds simulator decoding to eight wrappers and preserves the remaining wire bytes' do
    remaining = Meshtastic::Compressed.new(portnum: :TEXT_MESSAGE_APP, data: 'still encoded').to_proto
    wire = remaining
    8.times { wire = Meshtastic::Compressed.new(portnum: :SIMULATOR_APP, data: wire).to_proto }
    result = described_class.new.decode_payload(payload: wire, msg_type: :SIMULATOR_APP)
    8.times { result = result.fetch(:data) }
    expect(result).to eq(remaining)
  end

  it 'uses unknown port zero when a simulator wrapper omits its portnum' do
    wire = Meshtastic::Compressed.new(data: "\xff\x00".b).to_proto
    expect(described_class.new.decode_payload(payload: wire, msg_type: :SIMULATOR_APP)).to eq(data: "\xff\x00".b)
    expect(described_class.new.decode_payload(payload: nil, msg_type: :SIMULATOR_APP)).to eq({})
  end

  it 'decodes omitted simulator data using the known inner proto3 schema' do
    wire = Meshtastic::Compressed.new(portnum: :ROUTING_APP).to_proto
    expect(described_class.new.decode_payload(payload: wire, msg_type: :SIMULATOR_APP)).to eq(portnum: :ROUTING_APP, data: {})
  end

  it 'preserves malformed simulator wrappers and malformed inner data' do
    mesh = described_class.new
    raw = "\xff".b
    expect(mesh.decode_payload(payload: raw, msg_type: :SIMULATOR_APP)).to eq(raw)
    %i[POSITION_APP SIMULATOR_APP].each do |port|
      wire = Meshtastic::Compressed.new(portnum: port, data: raw).to_proto
      expect(mesh.decode_payload(payload: wire, msg_type: :SIMULATOR_APP)).to eq(portnum: port, data: raw)
    end
  end

  it 'still dispatches a non-simulator leaf after eight wrappers' do
    wire = Meshtastic::Compressed.new(portnum: :ROUTING_APP).to_proto
    7.times { wire = Meshtastic::Compressed.new(portnum: :SIMULATOR_APP, data: wire).to_proto }
    result = described_class.new.decode_payload(payload: wire, msg_type: :SIMULATOR_APP)
    8.times { result = result.fetch(:data) }
    expect(result).to eq({})
  end

  it 'scrubs text for display without mutating the original wire bytes' do
    raw = "hello\xff\x00".b.freeze
    result = described_class.new.decode_payload(payload: raw, msg_type: :TEXT_MESSAGE_APP)
    expect(result).to eq("hello\uFFFD\x00")
    expect(result.encoding).to eq(Encoding::UTF_8)
    expect(raw.bytes).to eq([104, 101, 108, 108, 111, 255, 0])
    expect(raw.encoding).to eq(Encoding::ASCII_8BIT)
  end
end

describe Meshtastic::MeshInterface do
  it 'treats sensor, alert, reply and range test payloads as text' do
    %i[DETECTION_SENSOR_APP ALERT_APP REPLY_APP RANGE_TEST_APP].each do |port|
      expect(described_class.new.decode_payload(payload: "\x08\x01", msg_type: port)).to eq("\x08\x01")
      expect(described_class.new.decode_payload(payload: nil, msg_type: port)).to eq('')
    end
  end

  it 'preserves opaque binary data rather than guessing a protobuf schema' do
    %i[UNKNOWN_APP SERIAL_APP PRIVATE_APP].each do |port|
      expect(described_class.new.decode_payload(payload: "\x08\x01".b, msg_type: port)).to eq("\x08\x01".b)
    end
  end

  it 'preserves malformed protobuf bytes rather than terminating reception' do
    expect(described_class.new.decode_payload(payload: "\xff".b, msg_type: :POSITION_APP)).to eq("\xff".b)
  end

  it 'preserves V2 wire bytes if the optional native library is unavailable' do
    require 'meshtastic/payload_compression'
    raw = "\x00compressed".b
    allow(Meshtastic::PayloadCompression).to receive(:decode_v2).and_raise(Meshtastic::PayloadCompression::Unavailable, 'missing libzstd')
    expect(described_class.new.decode_payload(payload: raw, msg_type: 78)).to eq(raw)
  end

  it 'uses the same codec dispatcher inside simulator wrappers' do
    raw = ['8767c714bdeb7c74'].pack('H*')
    wire = Meshtastic::Compressed.new(portnum: :TEXT_MESSAGE_COMPRESSED_APP, data: raw).to_proto
    expect(described_class.new.decode_payload(payload: wire, msg_type: 69)).to eq(portnum: :TEXT_MESSAGE_COMPRESSED_APP, data: 'Hello world')
  end

  it 'selects radio ciphertext by channel hash and refuses ambiguous keys' do
    key = 'k' * 32
    name = 'Custom'
    hash = (name.bytes + key.bytes).reduce(0, :^)
    cipher = OpenSSL::Cipher.new('AES-256-CTR')
    cipher.encrypt
    cipher.key = key
    cipher.iv = [42, 0, 123, 0].pack('V4')
    data = Meshtastic::Data.new(portnum: :NODE_STATUS_APP, payload: Meshtastic::StatusMessage.new(status: 'ok').to_proto)
    encrypted = cipher.update(data.to_proto) + cipher.final
    packet = { id: 42, from: 123, channel: hash, encrypted: encrypted }
    keys = { name => Base64.strict_encode64(key) }
    result = described_class.new.decrypt_packet(message: packet.dup, psks: keys)
    expect(result[:decoded]).to eq(data.to_h)
    collision = keys.merge(name.reverse => Base64.strict_encode64(key))
    result = described_class.new.decrypt_packet(message: packet.dup, psks: collision)
    expect(result[:decoded]).to be_nil
    expect(result[:encrypted]).to eq(encrypted)
  end

  it 'preserves already decoded PKI packets and ciphertext on invalid channel keys' do
    decoded = { decoded: { portnum: :ROUTING_APP }, pki_encrypted: true }
    expect(OpenSSL::Cipher).not_to receive(:new)
    expect(described_class.new.decrypt_packet(message: decoded, psks: {}, channel: 'test')).to eq(decoded)
    ['not base64!', Base64.strict_encode64('short')].each do |key|
      packet = { encrypted: 'ciphertext' }
      result = described_class.new.decrypt_packet(message: packet, psks: { test: key }, channel: 'test')
      expect(result[:encrypted]).to eq('ciphertext')
      expect(result[:decoded]).to be_nil
      expect(result[:decryption_error]).to match(/Unable to decode/)
    end
  end

  it 'preserves unsupported payloads without leaking them to diagnostic output' do
    [:PRIVATE_APP, 400, :UNRECOGNIZED_APP].each do |port|
      expect do
        result = described_class.new.decode_payload(payload: 'secret payload', msg_type: port)
        expect(result).to eq('secret payload')
      end.not_to output.to_stdout
    end
  end

  it 'rejects PKI on MQTT instead of falling back to channel encryption' do
    expect do
      described_class.new.send_data(
        data: Meshtastic::Data.new(portnum: :ADMIN_APP, payload: 'request'),
        port_num: Meshtastic::PortNum::ADMIN_APP,
        from: 1, to: 2, via: :mqtt, pki_encrypted: true, public_key: 'k' * 32
      )
    end.to raise_error(ArgumentError, /PKI.*radio/)
  end

  it 'rejects malformed recipient public keys' do
    expect do
      described_class.new.send_data(
        data: Meshtastic::Data.new(payload: 'request'),
        from: 1, to: 2, psks: nil, pki_encrypted: true, public_key: 'short'
      )
    end.to raise_error(ArgumentError, /32 bytes/)
  end

  it 'preserves explicit radio PKI parameters for remote administrative packets' do
    wire = described_class.new.send_data(
      data: Meshtastic::Data.new(portnum: :ADMIN_APP, payload: 'request'),
      port_num: Meshtastic::PortNum::ADMIN_APP,
      from: 1, to: 2, via: :radio, psks: nil,
      pki_encrypted: true, public_key: 'k' * 32
    )
    packet = Meshtastic::ToRadio.decode(wire).packet
    expect(packet.pki_encrypted).to be true
    expect(packet.public_key).to eq('k' * 32)
    expect(packet.decoded.payload).to eq('request')
  end
end
