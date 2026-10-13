# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Waypoint do
  it 'transmits a validated box using production radio framing and preserves security options' do
    frames = []
    conn = Object.new
    conn.define_singleton_method(:write) do |bytes|
      frames << bytes
      bytes.bytesize
    end
    conn.define_singleton_method(:flush) { true }
    handle = { serial_conn: conn, my_node_num: 42 }
    waypoint = described_class.build(fields: { bounding_box: { longitude_west_i: -10, longitude_east_i: 10 }, notify_on_exit: true })
    described_class.transmit(serial_obj: handle, waypoint: waypoint, to: '!aabbccdd', pki_encrypted: true, public_key: 'k' * 32, want_ack: true)
    packet = Meshtastic::ToRadio.decode(frames.last.byteslice(4..)).packet
    expect(packet.decoded.portnum).to eq(:WAYPOINT_APP)
    expect(described_class.decode(packet.decoded.payload)).to eq(waypoint)
    expect(packet).to have_attributes(pki_encrypted: true, public_key: 'k' * 32, want_ack: true)
    expect { described_class.transmit(serial_obj: handle, waypoint: described_class.new(geofence_radius: 1)) }.to raise_error(ArgumentError)
    expect(frames.length).to eq(1)
    expect { described_class.help }.to output(/#{described_class}\.transmit/).to_stdout
  end

  it 'validates bounds, geometry, notification types and firmware UTF-8 byte capacity' do
    invalid = [
      { latitude_i: 900_000_001, longitude_i: 0 }, { latitude_i: 0, longitude_i: -1_800_000_001 },
      { latitude_i: 0 }, { geofence_radius: 1 }, { geofence_radius: -1 }, { geofence_radius: 1.5 },
      { notify_on_enter: 1 }, { notify_on_exit: 'true' }, { notify_favorites_only: nil },
      { bounding_box: { longitude_west_i: 10, longitude_east_i: 9 } },
      { bounding_box: { latitude_south_i: 1, latitude_north_i: 0 } },
      { bounding_box: { latitude_north_i: 900_000_001 } }, { bounding_box: { latitude_north_i: nil } },
      { name: "bad\0name" }, { name: "\xff".b },
      { name: 'é' * 15 }, { description: 'x' * 100 }, { shape: :circle }
    ]
    invalid.each do |fields|
      expect { described_class.build(fields: fields) }.to raise_error(ArgumentError), fields.inspect
    end
    fields = { latitude_i: 0, longitude_i: 0, geofence_radius: 10,
               bounding_box: { longitude_west_i: -1_800_000_000, latitude_south_i: -900_000_000,
                               longitude_east_i: 1_800_000_000, latitude_north_i: 900_000_000 },
               name: 'x' * 29, description: 'x' * 99 }
    expect(described_class.build(fields: fields).bounding_box.latitude_north_i).to eq(900_000_000)
    expect(described_class.build(fields: { bounding_box: {} }).bounding_box).to eq(Meshtastic::BoundingBox.new)
  end

  it 'preserves the generated protobuf class and builds a circle with notification flags' do
    waypoint = described_class.build(fields: { id: 7, latitude_i: 450_000_000, longitude_i: -730_000_000,
                                               geofence_radius: 100, notify_on_enter: true, notify_on_exit: true, notify_favorites_only: true })
    expect(waypoint).to be_a(described_class)
    expect(described_class.decode(waypoint.to_proto).to_h).to include(geofence_radius: 100, notify_favorites_only: true)
    expect(described_class.build.to_proto).to eq(''.b)
  end
end
