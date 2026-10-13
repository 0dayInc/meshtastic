# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/payload_fixtures'
require 'socket'

describe Meshtastic::TCP do
  include PayloadFixtures

  it 'decodes every application fixture over the TCP framed receive path' do
    with_tcp_link do |handle, remote|
      payload_cases.each do |port, bytes, expected|
        remote.write(radio_frame(payload_radio(port, bytes)))
        received = Timeout.timeout(2) do
          described_class.subscribe(tcp_obj: handle) { |message| break message }
        end
        expect(received.dig(:packet, :decoded, :payload)).to eq(expected), "port #{port} bytes #{bytes.inspect}"
      end
    end
  end

  it 'preserves device security provenance and decrypts AEAD through TCP framing' do
    with_tcp_link do |handle, remote|
      packet = Meshtastic::MeshPacket.new(from: 123, to: 0xffffffff, id: 42,
                                          channel: 'Custom'.bytes.reduce(0, :^) ^ 0xae,
                                          encrypted: ['f0285b86af98b3f88815b9938ecf0ddf1693c987'].pack('H*'),
                                          xeddsa_signed: true, ack_proof_status: :ACK_PROOF_VALID)
      remote.write(radio_frame(Meshtastic::FromRadio.new(packet: packet)))
      received = Timeout.timeout(2) do
        described_class.subscribe(tcp_obj: handle, psks: { Custom: { psk: Base64.strict_encode64('k' * 16), use_aead: true } }) { |message| break message }
      end
      expect(received.dig(:packet, :decoded, :payload)).to eq('test')
      expect(received.dig(:packet, :security_provenance)).to include(source: :radio, verification: :device_reported,
                                                                     reported: { xeddsa_signed: true, ack_proof_status: :ACK_PROOF_VALID }, channel_authentication: :aead)
    end
  end

  def with_tcp_link(opts = {})
    local, remote = UNIXSocket.pair
    tcp_obj = described_class.connect({ socket: local, host: '127.0.0.1', port: 4403, want_config: false }.merge(opts))
    begin
      yield tcp_obj, remote
    ensure
      described_class.disconnect(tcp_obj: tcp_obj)
      remote.close unless remote.closed?
    end
  end

  def radio_frame(message)
    body = message.to_proto
    [Meshtastic::START1, Meshtastic::START2, body.bytesize].pack('CCn') + body
  end

  it 'writes a decoded ToRadio mesh packet over TCP without MQTT encryption' do
    with_tcp_link do |tcp_obj, remote|
      described_class.send_text(tcp_obj: tcp_obj, text: 'ping', to: '!ffffffff', channel: 0)
      expect(remote.read(32)).to eq(([Meshtastic::START2] * 32).pack('C*'))
      header = remote.read(4)
      packet = Meshtastic::ToRadio.decode(remote.read(header.unpack('CCn').last)).packet
      expect(packet.decoded.payload).to eq('ping')
      expect(packet.encrypted.to_s).to eq('')
    end
  end

  it 'forwards PKI text through the real TCP ToRadio codec' do
    with_tcp_link do |handle, remote|
      described_class.send_text(tcp_obj: handle, text: 'private', to: '!00000002', pki_encrypted: true, public_key: 'k' * 32)
      remote.read(32)
      header = remote.read(4)
      packet = Meshtastic::ToRadio.decode(remote.read(header.unpack('CCn').last)).packet
      expect(packet.pki_encrypted).to be true
      expect(packet.public_key).to eq('k' * 32)
      expect(packet.decoded.payload).to eq('private')
      expect(packet.encrypted).to be_empty
    end
  end

  it 'receives a framed FromRadio over TCP' do
    with_tcp_link do |tcp_obj, remote|
      remote.read(32)
      message = Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(
        from: 123, decoded: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP, payload: 'hello')
      ))
      remote.write(radio_frame(message))
      expect(described_class.recv_from_radio(tcp_obj: tcp_obj, timeout: 1)).to eq(message)
    end
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
