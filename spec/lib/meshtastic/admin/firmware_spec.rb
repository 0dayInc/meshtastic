# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'digest'
require 'tempfile'

RSpec.describe Meshtastic::Admin::Firmware do
  it 'dispatches explicitly to independent native bootloader protocols' do
    %i[esp_rom nordic_dfu].each do |protocol|
      name = protocol == :esp_rom ? :SerialBootloader : :NordicDFU
      implementation = described_class.const_get(name)
      options = { protocol: protocol, bytes: 'abc' }
      expect(implementation).to receive(:install).with(options).and_return(status: :verified)
      expect(described_class.install(options)).to eq(status: :verified)
    end
  end

  it 'validates reboot verification before upload and only verifies after loader success' do
    backend = double('BLE backend')
    verify = { transport: :tcp, connection: { host: '192.0.2.1' }, expected_version: '2.7.1' }
    options = { protocol: :unified_ble, backend: backend, bytes: 'abc' }
    expect(described_class::BLE).to receive(:install).with(options).ordered.and_return(status: :verified, bytes: 3, reboot_verified: false, boot_verified: false)
    expect(described_class).to receive(:verify_reboot).with(verify).ordered.and_return(status: :boot_verified, firmware_version: '2.7.1')
    expect(described_class.install(options.merge(verify: verify))).to include(status: :boot_verified, loader_status: :verified, bytes: 3, reboot_verified: true, boot_verified: true)
  end

  it 'rejects invalid verification settings before any destructive transfer' do
    base = { transport: :tcp, connection: { host: '192.0.2.1' }, expected_version: '2.7.1' }
    invalid = [true, {}, base.merge(timeout: 0), base.merge(timeout: Float::INFINITY),
               base.merge(reboot_delay: -1), base.merge(expected_version: ''), base.merge(transport: :mqtt),
               base.merge(connection: {}), base.merge(reconnect: true), base.merge(expected_node: '!bad'),
               base.merge(connection: { host: '192.0.2.1', socket: Object.new }),
               base.merge(connection: { host: '192.0.2.1', port: 0 }),
               base.merge(transport: :bluetooth, connection: { address: 'not-a-mac' })]
    invalid.each do |verify|
      expect(described_class::BLE).not_to receive(:install)
      expect { described_class.install(protocol: :unified_ble, bytes: 'abc', verify: verify) }.to raise_error(ArgumentError)
    end
  end

  it 'ignores cached metadata and checks a fresh correlated Admin reply after callback reconnect' do
    queue = Queue.new
    writer = Object.new
    writer.define_singleton_method(:write) do |bytes|
      request = Meshtastic::ToRadio.decode(bytes.byteslice(4..)).packet
      payload = Meshtastic::AdminMessage.new(get_device_metadata_response: Meshtastic::DeviceMetadata.new(firmware_version: 'wrong')).to_proto
      queue << Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: 123, decoded: Meshtastic::Data.new(portnum: :ADMIN_APP, request_id: request.id, payload: payload)))
      bytes.bytesize
    end
    writer.define_singleton_method(:flush) { true }
    handle = { serial_conn: writer, from_radio_queue: queue, my_node_num: 123, metadata: { firmware_version: 'expected' } }
    attempts = 0
    reconnect = lambda do |_options|
      attempts += 1
      raise Errno::ECONNREFUSED if attempts == 1

      handle
    end
    expect(Meshtastic::Serial).to receive(:wait_for_config).with(serial_obj: handle, timeout: 1).and_return(handle)
    expect(Meshtastic::Serial).to receive(:disconnect).with(serial_obj: handle)
    expect do
      described_class.verify_reboot(transport: :serial, reconnect: reconnect, expected_version: 'expected', reboot_delay: 0, timeout: 1)
    end.to raise_error(IOError, /version mismatch/)
  end

  it 'verifies fresh post-reboot metadata over a new production TCP PhoneAPI connection' do
    server = TCPServer.new('127.0.0.1', 0)
    worker = Thread.new do
      socket = server.accept
      buffer = +''.b
      loop do
        buffer << socket.read(1)
        next unless buffer.end_with?("\x94\xC3".b)

        length = socket.read(2).unpack1('n')
        request = Meshtastic::ToRadio.decode(socket.read(length))
        replies = if request.want_config_id.positive?
                    [Meshtastic::FromRadio.new(my_info: Meshtastic::MyNodeInfo.new(my_node_num: 123)),
                     Meshtastic::FromRadio.new(metadata: Meshtastic::DeviceMetadata.new(firmware_version: 'STALE')),
                     Meshtastic::FromRadio.new(config_complete_id: request.want_config_id)]
                  elsif request.packet
                    admin = Meshtastic::AdminMessage.decode(request.packet.decoded.payload)
                    expect(admin.get_device_metadata_request).to be true
                    payload = Meshtastic::AdminMessage.new(get_device_metadata_response: Meshtastic::DeviceMetadata.new(firmware_version: '2.7.1', hw_model: :HELTEC_V3)).to_proto
                    [Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: 123, decoded: Meshtastic::Data.new(portnum: :ADMIN_APP, request_id: request.packet.id, payload: payload)))]
                  else
                    []
                  end
        replies.each do |reply|
          bytes = reply.to_proto
          socket.write("\x94\xC3".b + [bytes.bytesize].pack('n') + bytes)
        end
        break if request.packet
      end
    ensure
      socket&.close
    end
    worker.report_on_exception = false
    result = described_class.verify_reboot(transport: :tcp, connection: { host: '127.0.0.1', port: server.addr[1] }, expected_version: '2.7.1', expected_node: 123, reboot_delay: 0, timeout: 2)
    expect(result).to include(status: :boot_verified, firmware_version: '2.7.1', node_num: 123)
    worker.value
  ensure
    worker&.kill
    worker&.join
    server&.close
  end
end

RSpec.shared_context 'a unified OTA TCP loader' do
  def with_loader(options = {}, &handler)
    server = TCPServer.new('127.0.0.1', 0)
    worker = Thread.new do
      client = server.accept
      handler.call(client)
    ensure
      client&.close
    end
    worker.report_on_exception = false
    yield_options = { protocol: :unified_wifi, host: '127.0.0.1', port: server.addr[1], bytes: 'abc', timeout: 0.3 }
    result = described_class.install(yield_options.merge(options))
    raise 'loader handshake did not finish' unless worker.join(1)

    worker.value
    result
  ensure
    worker&.kill
    worker&.join
    server&.close
  end
end

describe Meshtastic::Admin::Firmware do
  include_context 'a unified OTA TCP loader'

  it 'performs the unified WiFi handshake and waits for final verified OK' do
    result = with_loader do |client|
      expect(client.gets).to eq("VERSION\n")
      client.write("OK 1 2.7.0 3 v1.0\n")
      expect(client.gets).to eq("OTA 3 #{Digest::SHA256.hexdigest('abc')}\n")
      client.write("ERASING\nOK\n")
      expect(client.read(3)).to eq('abc')
      client.write("ACK\nOK\n")
    end
    expect(result).to include(status: :verified, bytes: 3, sha256: Digest::SHA256.hexdigest('abc'))
  end

  it 'retries refused loader connections before issuing the OTA command' do
    attempts = 0
    allow(Socket).to receive(:tcp).and_wrap_original do |original, *args, **keywords|
      attempts += 1
      raise Errno::ECONNREFUSED if attempts == 1

      original.call(*args, **keywords)
    end
    result = with_loader do |client|
      expect(client.gets).to eq("VERSION\n")
      client.write("OK 1 2.7.0 3 v1.0\n")
      client.gets
      client.write("OK\n")
      client.read(3)
      client.write("OK\n")
    end
    expect(result[:status]).to eq(:verified)
    expect(attempts).to eq(2)
  end

  it 'validates all install options before connecting or reading files' do
    defaults = { protocol: :unified_wifi, host: '127.0.0.1', bytes: 'abc' }
    [{ bytes: '' }, { bytes: 123 }, { bytes: nil }, { firmware: '/missing', bytes: 'abc' },
     { host: '' }, { port: 0 }, { timeout: 0 }, { timeout: Float::INFINITY },
     { retries: -1 }, { retry_delay: -1 }, { mode: :OTA_BLE }, { tcp_obj: Object.new },
     { to: '!aabbccdd' }, { protocol: :unified_wifi, bluetooth_obj: Object.new }].each do |invalid|
      expect(Socket).not_to receive(:tcp)
      expect { described_class.install(defaults.merge(invalid)) }.to raise_error(ArgumentError)
    end
  end

  it 'rejects invalid OTA modes and inconsistent or nonbinary supplied hashes before sending' do
    [{ mode: :UNKNOWN, bytes: 'abc' }, { ota_hash: Object.new },
     { ota_hash: 'a' * 32, bytes: 'abc' }, { ota_hash: 'a' * 64 }].each do |invalid|
      expect(Meshtastic::Admin).not_to receive(:send)
      expect { described_class.request_ota(invalid) }.to raise_error(ArgumentError)
    end
  end
end

describe Meshtastic::Admin::Firmware do
  include_context 'a unified OTA TCP loader'

  it 'hashes files and sends the real OTA and DFU Admin protobuf fields' do
    written = +''.b
    connection = Object.new
    connection.define_singleton_method(:write) do |data|
      written << data
      data.bytesize
    end
    connection.define_singleton_method(:flush) { true }
    serial = { serial_conn: connection, my_node_num: 0xb0b }
    described_class.request_ota(serial_obj: serial, bytes: 'abc', mode: :OTA_WIFI)
    length = written.byteslice(2, 2).unpack1('n')
    packet = Meshtastic::ToRadio.decode(written.byteslice(4, length)).packet
    admin = Meshtastic::AdminMessage.decode(packet.decoded.payload)
    expect(packet.decoded.portnum).to eq(:ADMIN_APP)
    expect(admin.ota_request.reboot_ota_mode).to eq(:OTA_WIFI)
    expect(admin.ota_request.ota_hash).to eq(Digest::SHA256.digest('abc'))
    written.clear
    described_class.enter_dfu(serial_obj: serial)
    length = written.byteslice(2, 2).unpack1('n')
    packet = Meshtastic::ToRadio.decode(written.byteslice(4, length)).packet
    expect(Meshtastic::AdminMessage.decode(packet.decoded.payload).enter_dfu_mode_request).to be true
    Tempfile.create('firmware') do |file|
      file.write('abc')
      file.flush
      expect(described_class.sha256(firmware: file.path)).to eq(Digest::SHA256.digest('abc'))
    end
  end

  it 'rejects malformed VERSION responses before sending OTA' do
    ["ERR Unknown Command\n", "OK\n", 'x' * 513, "OK 1 fw 2 loader"].each do |reply|
      expect do
        with_loader do |client|
          client.gets
          client.write(reply)
        end
      end.to raise_error(IOError)
    end
  end

  it 'surfaces loader handshake and final integrity errors without retrying OTA' do
    [false, true].each do |after_upload|
      expect do
        with_loader do |client|
          client.gets
          client.write("OK 1 fw 2 loader\n")
          client.gets
          if after_upload
            client.write("OK\n")
            client.read(3)
          end
          client.write("ERR Hash Mismatch\n")
        end
      end.to raise_error(IOError, /ERR Hash Mismatch/)
    end
  end

  it 'does not treat disconnect or ACK as final verification' do
    expect do
      with_loader do |client|
        client.gets
        client.write("OK 1 fw 2 loader\n")
        client.gets
        client.write("OK\n")
        client.read(3)
        client.write("ACK\n")
      end
    end.to raise_error(IOError, /closed before confirmation/)
  end

  it 'bounds a silent loader handshake and closes its connection' do
    expect do
      with_loader do |client|
        client.gets
        expect(client.read).to eq('')
      end
    end.to raise_error(Timeout::Error)
  end

  it 'exhausts bounded connection retries without sending any admin commands' do
    expect(Meshtastic::Admin).not_to receive(:send)
    expect(Socket).to receive(:tcp).exactly(3).times.and_raise(Errno::ECONNREFUSED)
    expect do
      described_class.install(protocol: :unified_wifi, host: '127.0.0.1', bytes: 'abc', retries: 2, retry_delay: 0)
    end.to raise_error(Errno::ECONNREFUSED)
  end

  it 'drains TCP ACKs during upload rather than deadlocking on backpressure' do
    allow(Socket).to receive(:tcp).and_wrap_original do |original, *args, **keywords|
      socket = original.call(*args, **keywords)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 1024)
      socket
    end
    bytes = 'a' * 1_048_576
    result = with_loader(bytes: bytes, timeout: 5) do |client|
      client.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 1024)
      client.gets
      client.write("OK 1 fw 2 loader\n")
      client.gets
      client.write("OK\n")
      received = +''
      while received.bytesize < bytes.bytesize
        received << client.read(1024)
        client.write("ACK\n" * 1024)
      end
      expect(received).to eq(bytes)
      client.write("OK\n")
    end
    expect(result[:bytes]).to eq(bytes.bytesize)
  end

  it 'rejects obsolete firmware XModem helpers and unhandled legacy OTA reboot' do
    %i[xmodem_blocks send_xmodem reboot_ota].each do |method|
      expect { described_class.public_send(method, bytes: 'abc') }
        .to raise_error(NotImplementedError)
    end
  end

  it 'rejects PhoneAPI and MQTT installation without sending any commands' do
    %i[serial_obj tcp_obj bluetooth_obj mqtt_obj].each do |transport|
      expect(Meshtastic::Admin).not_to receive(:send)
      expect { described_class.install(transport => Object.new, bytes: 'abc') }
        .to raise_error(NotImplementedError, /unified_wifi/)
    end
  end
end
