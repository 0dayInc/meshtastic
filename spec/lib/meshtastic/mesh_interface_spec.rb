# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::MeshInterface do
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
