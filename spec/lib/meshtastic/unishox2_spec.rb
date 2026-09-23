# frozen_string_literal: true

require 'spec_helper'
require 'meshtastic/unishox2'
require_relative '../../support/unishox_fixtures'

describe 'Meshtastic::Unishox2' do
  it 'bounds expansion and rejects invalid magic and back-references' do
    [UNISHOX_OVERFLOW, '00', '9800', 'ff'].each do |hex|
      expect { Meshtastic::Unishox2.decode(payload: [hex].pack('H*')) }.to raise_error(ArgumentError)
    end
    expect { Meshtastic::Unishox2.decode(payload: "\xff".b * 4097) }.to raise_error(ArgumentError, /4096/)
  end

  it 'terminates bounded malformed-input fuzz cases without unexpected exceptions' do
    random = Random.new(73)
    500.times do
      bytes = random.bytes(random.rand(1..100))
      begin
        decoded = Meshtastic::Unishox2.decode(payload: bytes)
        expect(decoded.bytesize).to be <= 4096
        expect(decoded).to be_valid_encoding
      rescue ArgumentError
        # Malformed streams must fail closed, not crash or allocate indefinitely.
      end
    end
  end

  it 'decodes default-preset reference encoder vectors byte for byte' do
    UNISHOX_FIXTURES.each do |text, hex|
      expect(Meshtastic::Unishox2.decode(payload: [hex].pack('H*'))).to eq(text)
    end
  end
end
