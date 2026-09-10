# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::ATAK do
  def fake_serial_obj
    written = +''.b
    serial_conn = Object.new
    serial_conn.define_singleton_method(:write) do |b|
      written << b
      b.bytesize
    end
    serial_conn.define_singleton_method(:flush) { true }
    serial_conn.define_singleton_method(:closed?) { false }
    serial_conn.define_singleton_method(:close) { true }
    { serial_conn: serial_conn, written: written, my_node_num: 0xb0b }
  end

  def decode_to_radio(serial_obj)
    frame = serial_obj[:written]
    body = frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))
    Meshtastic::ToRadio.decode(body).packet
  end

  it 'encodes V1 GeoChat with contact, group, and status' do
    packet = described_class.encode_v1(
      message: 'ATAK chat',
      to: 'ANDROID-aabbccdd',
      callsign: 'ALPHA',
      device_callsign: 'RADIO-1',
      team: :Cyan,
      role: :TeamMember,
      battery: 87
    )
    expect(packet).to be_a(Meshtastic::TAKPacket)
    expect(packet.chat.message).to eq('ATAK chat')
    expect(packet.chat.to).to eq('ANDROID-aabbccdd')
    expect(packet.contact.callsign).to eq('ALPHA')
    expect(packet.group.team).to eq(:Cyan)
    expect(packet.group.role).to eq(:TeamMember)
    expect(packet.status.battery).to eq(87)
  end

  it 'encodes V1 PLI with 1e7-scaled coordinates' do
    packet = described_class.encode_v1(
      lat: 37.7749,
      lon: -122.4194,
      altitude: 12,
      speed: 3,
      course: 90
    )
    expect(packet.pli.latitude_i).to eq(377_749_000)
    expect(packet.pli.longitude_i).to eq(-1_224_194_000)
    expect(packet.pli.altitude).to eq(12)
    expect(packet.pli.speed).to eq(3)
    expect(packet.pli.course).to eq(90)
  end

  it 'sends V1 GeoChat on ATAK_PLUGIN' do
    serial_obj = fake_serial_obj
    described_class.send_chat(serial_obj: serial_obj, message: 'ATAK chat')
    packet = decode_to_radio(serial_obj)
    expect(packet.decoded.portnum).to eq(:ATAK_PLUGIN)
    tak = Meshtastic::TAKPacket.decode(packet.decoded.payload)
    expect(tak.chat.message).to eq('ATAK chat')
  end

  it 'sends V1 PLI on ATAK_PLUGIN' do
    serial_obj = fake_serial_obj
    described_class.send_pli(serial_obj: serial_obj, lat: 37.7749, lon: -122.4194)
    packet = decode_to_radio(serial_obj)
    expect(packet.decoded.portnum).to eq(:ATAK_PLUGIN)
    tak = Meshtastic::TAKPacket.decode(packet.decoded.payload)
    expect(tak.pli.latitude_i).to eq(377_749_000)
  end

  it 'encodes uncompressed V2 GeoChat wire frames with flags 0xFF' do
    wire = described_class.encode_v2(
      callsign: 'ALPHA',
      team: :Cyan,
      role: :TeamMember,
      lat: 37.7749,
      lon: -122.4194,
      message: 'v2 chat'
    )
    expect(wire.getbyte(0)).to eq(0xFF)
    v2 = Meshtastic::TAKPacketV2.decode(wire.byteslice(1..))
    expect(v2.chat.message).to eq('v2 chat')
    expect(v2.callsign).to eq('ALPHA')
    expect(v2.latitude_i).to eq(377_749_000)
  end

  it 'round-trips V2 typed payloads' do
    {
      aircraft: Meshtastic::AircraftTrack.new(icao: 'ABC123', flight: 'N1'),
      shape: Meshtastic::DrawnShape.new(kind: :Kind_Circle, major_cm: 1000),
      marker: Meshtastic::Marker.new(kind: :Kind_Spot),
      route: Meshtastic::Route.new(prefix: 'R1'),
      casevac: Meshtastic::CasevacReport.new(title: 'CASEVAC'),
      emergency: Meshtastic::EmergencyAlert.new(type: :Type_Alert911),
      task: Meshtastic::TaskRequest.new(task_type: 'recon', note: 'look'),
      taktalk: Meshtastic::TakTalkMessage.new(text: 'voice', chatroom_id: 'room1'),
      taktalk_room: Meshtastic::TakTalkRoomData.new(room_id: 'room1', room_name: 'Ops'),
      rab: Meshtastic::RangeAndBearing.new(range_cm: 500)
    }.each do |field, value|
      v2 = described_class.build_v2(field => value, callsign: 'ALPHA')
      expect(v2.public_send(field)).to eq(value)
      decoded = described_class.decode_v2(wire: described_class.wrap_v2(packet: v2))
      expect(decoded.public_send(field).to_h).to eq(value.to_h)
    end
  end

  it 'sends V2 packets on ATAK_PLUGIN_V2' do
    serial_obj = fake_serial_obj
    described_class.send_v2(serial_obj: serial_obj, message: 'v2 chat', callsign: 'ALPHA')
    packet = decode_to_radio(serial_obj)
    expect(packet.decoded.portnum).to eq(:ATAK_PLUGIN_V2)
    decoded = described_class.decode_v2(payload: packet.decoded.payload)
    expect(decoded.chat.message).to eq('v2 chat')
  end

  it 'zlib-compresses CoT XML on ATAK_FORWARDER' do
    serial_obj = fake_serial_obj
    cot = '<event type="b-m-p-s-m" uid="marker-1"><point lat="37.77" lon="-122.41"/></event>'
    described_class.send_cot(serial_obj: serial_obj, cot: cot)
    packet = decode_to_radio(serial_obj)
    expect(packet.decoded.portnum).to eq(:ATAK_FORWARDER)
    xml = described_class.decompress_cot(payload: packet.decoded.payload)
    expect(xml).to include('marker-1')
  end

  it 'decodes inbound payloads by portnum' do
    v1 = described_class.encode_v1(message: 'hi')
    expect(described_class.decode(payload: v1.to_proto, portnum: :ATAK_PLUGIN).chat.message).to eq('hi')

    v2 = described_class.encode_v2(message: 'v2')
    expect(described_class.decode(payload: v2, portnum: :ATAK_PLUGIN_V2).chat.message).to eq('v2')

    cot = described_class.compress_cot(cot: '<event uid="x"/>')
    expect(described_class.decode(payload: cot, portnum: :ATAK_FORWARDER)).to include('uid="x"')
  end

  it 'keeps send as a V1 GeoChat alias' do
    serial_obj = fake_serial_obj
    described_class.send(serial_obj: serial_obj, message: 'ATAK chat')
    packet = decode_to_radio(serial_obj)
    expect(packet.decoded.portnum).to eq(:ATAK_PLUGIN)
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/ATAK_PLUGIN_V2/).to_stdout
  end
end
