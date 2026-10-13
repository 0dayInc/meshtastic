# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Meshtastic::Admin::Firmware, 'v2.8.1 migration (no hardware)' do
  let(:version) { '2.8.1.8e6a88d' }
  let(:public_key) { 'k'.b * 32 }

  # Hardware writes are mocked; ToRadio, AdminMessage and FromRadio codecs and
  # Admin source/request correlation are production code, not mocked requests.
  def radio(kind, version:, key:, decoys: false, fresh: true)
    queue = Queue.new
    requests = []
    writer = Object.new
    writer.define_singleton_method(:write) do |bytes|
      packet = Meshtastic::ToRadio.decode(kind == :bluetooth ? bytes : bytes.byteslice(4..)).packet
      request = Meshtastic::AdminMessage.decode(packet.decoded.payload)
      requests << [packet.to, request.payload_variant]
      response = if request.get_owner_request
                   Meshtastic::AdminMessage.new(get_owner_response: Meshtastic::User.new(public_key: key))
                 else
                   Meshtastic::AdminMessage.new(get_device_metadata_response: Meshtastic::DeviceMetadata.new(firmware_version: version))
                 end
      sources = decoys ? [[999, packet.id], [456, packet.id - 1]] : []
      sources << [456, packet.id] if fresh
      sources.each do |from, id|
        frame = Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: from, decoded: Meshtastic::Data.new(portnum: :ADMIN_APP, request_id: id, payload: response.to_proto)))
        queue << Meshtastic::FromRadio.decode(frame.to_proto)
      end
      bytes.bytesize
    end
    writer.define_singleton_method(:flush) { true }
    handle = { my_node_num: 456, from_radio_queue: queue, tx_mutex: Mutex.new, metadata: { firmware_version: '2.8.1.8e6a88d' } }
    handle[kind == :bluetooth ? :bluetooth_conn : :serial_conn] = writer
    handle[:tcp_socket] = writer if kind == :tcp
    transport = { serial: Meshtastic::Serial, bluetooth: Meshtastic::Bluetooth, tcp: Meshtastic::TCP }.fetch(kind)
    allow(transport).to receive(:wait_for_config).and_return(handle)
    allow(transport).to receive(:disconnect)
    [handle, requests]
  end

  it 'rejects a reconnect callback returning a different transport before Admin traffic' do
    handle, requests = radio(:serial, version: version, key: public_key)
    allow(Meshtastic::Bluetooth).to receive(:wait_for_config).and_return(handle)
    expect(Meshtastic::Serial).to receive(:disconnect).with(serial_obj: handle)
    expect(Meshtastic::Bluetooth).not_to receive(:disconnect)
    expect do
      described_class.verify_reboot(transport: :bluetooth, reconnect: ->(_) { handle }, expected_version: version, reboot_delay: 0, timeout: 0.1)
    end.to raise_error(ArgumentError, /transport/)
    expect(requests).to be_empty
  end

  it 'validates migration identity and explicit endpoint settings before invoking any loader' do
    base = { transport: :serial, connection: { block_dev: '/dev/ttyACM0' }, expected_version: version }
    invalid = [{ expected_public_key: 'short' }, { expected_public_key: 'a' * 64 }, { expected_public_key: "\x00" * 32 },
               { previous_node: 123 }, { expected_node: 0xffffffff }, { previous_node: '!0000007b', expected_public_key: public_key },
               { to: '!000001c8' }, { connection: {} }, { transport: :mqtt }]
    expect(described_class::BLE).not_to receive(:install)
    invalid.each do |options|
      expect { described_class.install(protocol: :unified_ble, bytes: 'abc', verify: base.merge(options)) }.to raise_error(ArgumentError)
    end
  end

  it 'documents the public continuity options in actual runtime help' do
    expect { described_class.help }.to output(/expected_public_key:.*previous_node:/m).to_stdout
  end

  %i[serial bluetooth tcp].each do |kind|
    %w[2.8.1.wrongsuffix 2.8.1 2.8.0.8e6a88d 2.7.23.b246bcd].each do |wrong|
      it "rejects #{wrong} despite exact cached metadata over #{kind}" do
        handle, = radio(kind, version: wrong, key: public_key)
        expect do
          described_class.verify_reboot(transport: kind, reconnect: ->(_) { handle }, expected_version: version,
                                        expected_public_key: public_key, previous_node: 123, reboot_delay: 0, timeout: 1)
        end.to raise_error(IOError, /version mismatch/)
      end
    end

    it "does not accept an arbitrary new node with another key over #{kind}" do
      handle, requests = radio(kind, version: version, key: 'x' * 32)
      expect do
        described_class.verify_reboot(transport: kind, reconnect: ->(_) { handle }, expected_version: version,
                                      expected_public_key: public_key, previous_node: 123, reboot_delay: 0, timeout: 1)
      end.to raise_error(IOError, 'Post-reboot public-key identity mismatch')
      expect(requests).to eq([[456, :get_owner_request]])
    end

    it "does not relax an explicitly strict numeric expectation over #{kind}" do
      handle, requests = radio(kind, version: version, key: public_key)
      expect do
        described_class.verify_reboot(transport: kind, reconnect: ->(_) { handle }, expected_version: version,
                                      expected_node: 123, expected_public_key: public_key, reboot_delay: 0, timeout: 1)
      end.to raise_error(IOError, /node identity mismatch/)
      expect(requests).to be_empty
    end

    [false, true].each do |owner|
      it "rejects stale or wrong-source #{owner ? 'owner' : 'metadata'} and retains unrelated traffic over #{kind}" do
        handle, = radio(kind, version: version, key: public_key, decoys: true, fresh: false)
        identity = owner ? { expected_public_key: public_key } : {}
        expect do
          described_class.verify_reboot({ transport: kind, reconnect: ->(_) { handle }, expected_version: version,
                                          reboot_delay: 0, timeout: 0.05 }.merge(identity))
        end.to raise_error(Timeout::Error)
        expect(handle[:from_radio_queue].size).to eq(2)
      end
    end

    it "allows an explicit key-continuous node migration over #{kind} without exposing keys" do
      handle, requests = radio(kind, version: version, key: public_key, decoys: true)
      result = described_class.verify_reboot(transport: kind, reconnect: ->(_) { handle }, expected_version: version,
                                             expected_public_key: public_key, previous_node: 123, reboot_delay: 0, timeout: 1)
      expect(result).to include(status: :boot_verified, node_num: 456, previous_node_num: 123,
                                node_id: '!000001c8', previous_node_id: '!0000007b', node_changed: true,
                                identity: :public_key_continuity)
      expect(requests).to eq([[456, :get_owner_request], [456, :get_device_metadata_request]])
      expect(result.inspect).not_to include(public_key)
      expect(handle[:from_radio_queue].size).to eq(4)
    end
  end
end
