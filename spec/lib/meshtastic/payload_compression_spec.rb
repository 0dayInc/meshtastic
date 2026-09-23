# frozen_string_literal: true

require 'spec_helper'
require 'meshtastic/payload_compression'
require_relative '../../support/tak_codec_fixtures'

describe 'Meshtastic::PayloadCompression' do
  it 'rejects oversized decoded frames without allocating their advertised size' do
    # libzstd ZSTD_compress level 3, input: 4097 a bytes; magic stripped.
    bomb = ['0060010f4d00001061610100fcf70116'].pack('H*')
    expect { Meshtastic::PayloadCompression.decode_v2(payload: bomb) }.to raise_error(ArgumentError, /4096/)
    expect { Meshtastic::PayloadCompression.decode_v2(payload: "\xff".b + ('a' * 4097)) }.to raise_error(ArgumentError, /4097/)
  end

  it 'ignores reserved flag bits and rejects trailing or truncated frames' do
    _, hex, proto = TAK_CODEC_FIXTURES.first
    wire = [hex].pack('H*')
    wire.setbyte(0, wire.getbyte(0) | 0xc0)
    expect(Meshtastic::PayloadCompression.decode_v2(payload: wire)).to eq([proto].pack('H*'))
    ["#{wire}x", wire.byteslice(0...-1), "\x02".b, ''.b].each do |bad|
      expect { Meshtastic::PayloadCompression.decode_v2(payload: bad) }.to raise_error(ArgumentError)
    end
  end

  it 'does not require a native library for raw proto3 empty messages' do
    expect(Meshtastic::PayloadCompression).not_to receive(:native)
    expect(Meshtastic::PayloadCompression.decode_v2(payload: "\xff".b)).to eq(''.b)
  end

  it 'reports native availability failures explicitly' do
    require 'fiddle'
    allow(Fiddle).to receive(:dlopen).and_raise(Fiddle::DLError, 'not installed')
    expect { Meshtastic::PayloadCompression.decode_v2(payload: [TAK_CODEC_FIXTURES.first[1]].pack('H*')) }
      .to raise_error(Meshtastic::PayloadCompression::Unavailable, /libzstd/)
  end

  it 'decodes every official SDK golden frame to the exact protobuf bytes' do
    TAK_CODEC_FIXTURES.each do |name, wire, protobuf|
      expect(Meshtastic::PayloadCompression.decode_v2(payload: [wire].pack('H*')))
        .to eq([protobuf].pack('H*')), name
    end
  end
end
