# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Meshtastic::Forwarder' do
  it 'decodes a libcotshrink wire event rather than treating it as zlib XML' do
    require 'meshtastic/forwarder'
    # Hand-authored protobuf wire: uid="test", omitted type means PLI.
    result = Meshtastic::Forwarder.decode(payload: "\x0a\x04test".b)
    expect(result[:format]).to eq(:libcotshrink_protobuf)
    expect(result[:event]).to include(uid: 'test', type: 'a-f-G-U-C', lat: 0.0, lon: 0.0)
  end

  it 'unwraps GZIP and decodes packed fields and nested detail' do
    require 'meshtastic/forwarder'
    require 'zlib'
    packed = (123 << 39) | (60 << 16) | 3000
    message = Meshtastic::ForwarderProtobuf::CotEvent.new(
      uid: 'example', lat: 123_456_789, lon: -987_654_321,
      customBytes: packed, customBytesExt: 2 << 61,
      detail: { contact: { callsign: 'EXAMPLE' } }
    )
    result = Meshtastic::Forwarder.decode(payload: Zlib.gzip(message.to_proto), start_of_year: Time.utc(2025))
    expect(result).to include(compression: :gzip)
    expect(result[:protobuf][:detail][:contact][:callsign]).to eq('EXAMPLE')
    expect(result[:event]).to include(lat: 12.3456789, lon: -98.7654321, hae: 100.0,
                                      time: '2025-01-01T00:02:03Z', stale: '2025-01-01T00:03:03Z', how: 'm-g')
    expect(result[:extensions]).to include(battery: 0, readiness: false, role: 'Team Member')
  end

  it 'bounds compressed and decompressed input and rejects damaged gzip' do
    require 'meshtastic/forwarder'
    require 'zlib'
    expect { Meshtastic::Forwarder.decode(payload: Zlib.gzip('a' * 100_000), max_bytes: 100) }.to raise_error(ArgumentError, /limit/)
    expect { Meshtastic::Forwarder.decode(payload: 'a' * 101, max_bytes: 100) }.to raise_error(ArgumentError, /limit/)
    expect { Meshtastic::Forwarder.decode(payload: Zlib.gzip('abc')[0...-4]) }.to raise_error(ArgumentError, /GZIP/)
  end

  it 'recognizes EXI but explicitly reports the missing decoder' do
    require 'meshtastic/forwarder'
    ["\x80\x00".b, "$EXI\x80\x00".b].each do |payload|
      expect { Meshtastic::Forwarder.decode(payload: payload) }.to raise_error(Meshtastic::Forwarder::UnsupportedFormat, /EXI/)
    end
  end

  it 'does not invent a year and honors compact null sentinels' do
    require 'meshtastic/forwarder'
    message = Meshtastic::ForwarderProtobuf::CotEvent.new(uid: 'example', customBytesExt: 32 << 55)
    result = Meshtastic::Forwarder.decode(payload: message.to_proto)
    expect(result[:event]).to include(time_offset_seconds: 0, stale_after_seconds: 0)
    expect(result[:event]).not_to have_key(:time)
    expect(result[:extensions][:geopointsrc]).to be_nil
  end

  it 'decodes real Forwarder nibble headers and separates incomplete chunks' do
    require 'meshtastic/forwarder'
    result = Meshtastic::Forwarder.decode_packet(payload: "\x01\x0a\x04test".b)
    expect(result[:event][:uid]).to eq('test')
    expect(Meshtastic::Forwarder.decode_packet(payload: "\x02\x0a\x04".b)).to include(
      format: :forwarder_fragment, index: 0, count: 2, body: "\x0a\x04".b
    )
    result = Meshtastic::Forwarder.decode_chunks(chunks: ["\x12test".b, "\x02\x0a\x04".b])
    expect(result[:event][:uid]).to eq('test')
    expect { Meshtastic::Forwarder.decode_chunks(chunks: ["\x02\x0a\x04".b]) }.to raise_error(ArgumentError, /missing/)
    expect { Meshtastic::Forwarder.decode_packet(payload: "\x22bad".b) }.to raise_error(ArgumentError, /header/)
    expect { Meshtastic::Forwarder.decode_chunks(chunks: ["\x02a".b, "\x02b".b]) }.to raise_error(ArgumentError, /duplicate/)
  end

  it 'returns discovery broadcasts separately from CoT' do
    require 'meshtastic/forwarder'
    result = Meshtastic::Forwarder.decode_packet(payload: "\x01ATAKBCAST,!aabbccdd,example,EXAMPLE,1".b)
    expect(result).to include(format: :forwarder_discovery, mesh_id: '!aabbccdd', uid: 'example', callsign: 'EXAMPLE', initial: true)
  end

  it 'decodes independent protoc wire with the complete upstream detail graph' do
    require 'meshtastic/forwarder'
    # Produced by protoc --encode against pinned upstream .proto files, not this Ruby encoder.
    wire = ['0a0e736368656d612d6669787475726518aab4de7520e1a2f3ad07282a300739b872c102006702004100000000000000404a1e0a090a074558414d504c452a0042008201008a01009201009a0100b20100'].pack('H*')
    result = Meshtastic::Forwarder.decode(payload: wire)
    expect(result[:event]).to include(uid: 'schema-fixture', lat: 12.3456789, lon: -98.7654321, ce: 42, le: 7)
    expect(result[:protobuf][:detail].keys).to contain_exactly(:contact, :remarks, :chat, :route, :sensor, :video, :geoFence, :medevac)
  end

  it 'enforces packet limits even for discovery and incomplete fragments' do
    require 'meshtastic/forwarder'
    expect { Meshtastic::Forwarder.decode_packet(payload: "\x02abc".b, max_bytes: 2) }.to raise_error(ArgumentError, /limit/)
    expect { Meshtastic::Forwarder.decode_packet(payload: "\x01ATAKBCAST,a,b,c,1".b, max_bytes: 2) }.to raise_error(ArgumentError, /limit/)
    expect { Meshtastic::Forwarder.decode_chunks(chunks: ["\x02abc".b, "\x12def".b], max_bytes: 5) }.to raise_error(ArgumentError, /limit/)
  end

  it 'rejects invalid mapped values and malformed protobuf' do
    require 'meshtastic/forwarder'
    message = Meshtastic::ForwarderProtobuf::CotEvent.new(uid: 'example', customBytesExt: 7 << 61)
    expect { Meshtastic::Forwarder.decode(payload: message.to_proto) }.to raise_error(ArgumentError, /mapping/)
    expect { Meshtastic::Forwarder.decode(payload: "\x0a\x08x".b) }.to raise_error(ArgumentError, /protobuf/)
  end
end
