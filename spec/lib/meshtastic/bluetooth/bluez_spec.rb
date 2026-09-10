# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Meshtastic::Bluetooth::BlueZ do # rubocop:disable Metrics/BlockLength
  let(:address) { 'AA:BB:CC:DD:EE:FF' }

  let(:device_path) { '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF' }
  let(:service_path) { "#{device_path}/service0001" }
  let(:socket) { instance_double(UNIXSocket, close: nil, closed?: false) }
  let(:bus) { double('private D-Bus connection', message_queue: double(socket: socket)) }
  let(:calls) { [] }
  let(:objects) do
    {
      '/org/bluez/hci0' => { 'org.bluez.Adapter1' => { 'Powered' => true } },
      device_path => { 'org.bluez.Device1' => { 'Address' => address, 'Adapter' => '/org/bluez/hci0', 'Name' => 'Mesh', 'UUIDs' => [described_class::SERVICE_UUID], 'Paired' => true, 'Connected' => false, 'ServicesResolved' => true } },
      service_path => { 'org.bluez.GattService1' => { 'UUID' => described_class::SERVICE_UUID, 'Device' => device_path } },
      "#{service_path}/to" => { 'org.bluez.GattCharacteristic1' => { 'UUID' => described_class::TORADIO_UUID, 'Service' => service_path } },
      "#{service_path}/from" => { 'org.bluez.GattCharacteristic1' => { 'UUID' => described_class::FROMRADIO_UUID, 'Service' => service_path } }
    }
  end
  let(:backend) { described_class.new(address: address, timeout: 0.03) }

  before do
    allow(DBus::ASystemBus).to receive(:allocate).and_return(bus)
    allow(bus).to receive(:initialize)
    allow(bus).to receive(:send_sync_or_async) do |message|
      calls << message
      case message.member
      when 'GetManagedObjects' then [objects]
      when 'GetAll' then [objects.fetch(message.path).fetch(message.params.first.last)]
      when 'Connect' then objects[device_path]['org.bluez.Device1']['Connected'] = true
                          []
      when 'Disconnect' then objects[device_path]['org.bluez.Device1']['Connected'] = false
                             []
      else []
      end
    end
  end

  it 'connects a paired device on the chosen powered adapter' do
    expect(backend.connect).to equal(backend)
    expect(calls.find { |call| call.member == 'Connect' }.path).to eq(device_path)
  end

  it 'requires pre-pairing and releases the bus after a refused connection' do
    objects[device_path]['org.bluez.Device1']['Paired'] = false
    expect { backend.connect }.to raise_error(IOError, /bluetoothctl pair AA:BB:CC:DD:EE:FF/)
    expect(calls.map(&:member)).not_to include('Connect', 'Pair', 'Disconnect')
    expect(socket).to have_received(:close).once
  end

  it 'rejects unavailable or unpowered adapters and missing devices without connecting' do
    objects['/org/bluez/hci0']['org.bluez.Adapter1']['Powered'] = false
    expect { backend.connect }.to raise_error(IOError, /powered/)
    objects.delete('/org/bluez/hci0')
    expect { backend.connect }.to raise_error(IOError, /adapter/)
    objects['/org/bluez/hci0'] = { 'org.bluez.Adapter1' => { 'Powered' => true } }
    objects.delete(device_path)
    expect { backend.connect }.to raise_error(IOError, /not found/)
    expect(calls.map(&:member)).not_to include('Connect')
  end

  it 'writes one unframed protobuf to the characteristic scoped to the chosen device and service' do
    wrong_service = "#{device_path}/wrong"
    decoys = {
      '/other/service' => { 'org.bluez.GattService1' => { 'UUID' => described_class::SERVICE_UUID, 'Device' => '/other' } },
      '/other/to' => { 'org.bluez.GattCharacteristic1' => { 'UUID' => described_class::TORADIO_UUID, 'Service' => '/other/service' } },
      "#{wrong_service}/to" => { 'org.bluez.GattCharacteristic1' => { 'UUID' => described_class::TORADIO_UUID, 'Service' => wrong_service } }
    }
    objects.replace(decoys.merge(objects))
    bytes = "\x00\xFF\x94\xC3".b * 100
    backend.connect
    expect(backend.write(bytes)).to eq(bytes.bytesize)
    writes = calls.select { |call| call.member == 'WriteValue' }
    expect(writes.size).to eq(1)
    expect(writes.first.path).to eq("#{service_path}/to")
    expect(writes.first.params).to eq([['ay', bytes.bytes], ['a{sv}', { 'type' => %w[s request] }]])
  end

  it 'reads raw binary FromRadio bytes and returns binary empty strings for an empty queue' do
    backend.connect

    allow(bus).to receive(:send_sync_or_async).with(have_attributes(member: 'ReadValue')).and_return([[0, 255, 128]], [[]])
    expect(backend.read).to eq("\x00\xFF\x80".b)
    expect(backend.read).to eq(''.b)
    expect(bus).to have_received(:send_sync_or_async).with(have_attributes(path: "#{service_path}/from", member: 'ReadValue', params: [['a{sv}', {}]])).twice
  end

  it 'waits for ServicesResolved before selecting required characteristics, bounded by timeout' do
    objects[device_path]['org.bluez.Device1']['ServicesResolved'] = false
    expect { backend.connect }.to raise_error(IOError, /ServicesResolved.*timed out/)
    expect(calls.map(&:member)).to include('Disconnect')
    expect(socket).to have_received(:close).once
  end

  it 'requires both characteristics under the Meshtastic service during connect' do
    objects.delete("#{service_path}/from")
    expect { backend.connect }.to raise_error(IOError, /characteristic/)
    expect(calls.map(&:member)).to include('Disconnect')
  end

  it 'raises on disconnected reads and writes instead of treating disconnect as an empty queue' do
    backend.connect
    objects[device_path]['org.bluez.Device1']['Connected'] = false
    allow(bus).to receive(:send_sync_or_async).with(have_attributes(member: 'ReadValue')).and_return([[]])
    expect { backend.read }.to raise_error(IOError, /disconnected/)
    expect { backend.write('data') }.to raise_error(IOError, /disconnected/)
    expect(calls.map(&:member)).not_to include('ReadValue', 'WriteValue')
  end

  it 'bounds a stalled D-Bus call and discards the interrupted connection' do
    backend.connect
    allow(bus).to receive(:send_sync_or_async).with(have_attributes(member: 'ReadValue')) {
      sleep 1
      [[]]
    }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { backend.read }.to raise_error(IOError, /timed out/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    expect(socket).to have_received(:close).once
    expect { backend.read }.to raise_error(IOError, /disconnected/)
  end

  it 'bounds D-Bus initialization and closes partially initialized resources' do
    allow(bus).to receive(:initialize) { sleep 1 }
    expect { backend.connect }.to raise_error(IOError, /timed out/)
    expect(socket).to have_received(:close).once
  end

  it 'serializes read, write and close on the private D-Bus connection' do
    connection = described_class.new(address: address, timeout: 1)
    connection.connect
    entered = Queue.new
    release = Queue.new
    reading = false
    overlap = false
    allow(bus).to receive(:send_sync_or_async).with(have_attributes(member: 'ReadValue')) do
      reading = true
      entered << true
      release.pop
      reading = false
      [[]]
    end
    %w[WriteValue Disconnect].each do |member|
      allow(bus).to receive(:send_sync_or_async).with(have_attributes(member: member)) {
        overlap ||= reading
        []
      }
    end
    reader = Thread.new { connection.read }
    entered.pop
    writer = Thread.new do
      connection.write('data')
    rescue StandardError
      IOError
    end
    closer = Thread.new { connection.close }
    sleep 0.02
    release << true
    [reader, writer, closer].each(&:join)
    expect(overlap).to be(false)
    expect(socket).to have_received(:close).once
    connection.close
    expect(socket).to have_received(:close).once
  end

  it 'scans only Meshtastic devices on the requested adapter and releases its discovery session' do
    objects['/other'] = { 'org.bluez.Device1' => objects[device_path]['org.bluez.Device1'].merge('Adapter' => '/org/bluez/hci1') }
    objects['/nonmesh'] = { 'org.bluez.Device1' => objects[device_path]['org.bluez.Device1'].merge('UUIDs' => []) }
    expect(described_class.scan(adapter: 'hci0', timeout: 0.001)).to eq([{ address: address, name: 'Mesh', paired: true }])
    expect(calls.map(&:member)).to include('StartDiscovery', 'StopDiscovery')
    expect(calls.map(&:member)).not_to include('Connect', 'Pair', 'Disconnect')
    expect(calls.find { |call| call.member == 'StartDiscovery' }.path).to eq('/org/bluez/hci0')
    expect(socket).to have_received(:close).once
  end

  it 'rejects invalid adapter names and nonpositive or nonfinite timeouts' do
    ['../hci0', 'hci0/foo', nil].each do |adapter|
      expect { described_class.new(address: address, adapter: adapter) }.to raise_error(ArgumentError, /adapter/)
    end
    [0, -1, Float::INFINITY, Float::NAN, '5'].each do |timeout|
      expect { described_class.new(address: address, timeout: timeout) }.to raise_error(ArgumentError, /timeout/)
    end
  end

  it 'rejects malformed Bluetooth addresses before accessing D-Bus' do
    expect { described_class.new(address: 'AA-BB-CC-DD-EE-FF') }.to raise_error(ArgumentError, /address/)
  end
end
