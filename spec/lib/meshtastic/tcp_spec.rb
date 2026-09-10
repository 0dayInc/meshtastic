# frozen_string_literal: true

require 'spec_helper'
require 'socket'

describe Meshtastic::TCP do
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
