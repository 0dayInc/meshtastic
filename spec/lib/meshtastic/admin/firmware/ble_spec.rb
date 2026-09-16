# frozen_string_literal: true

require 'spec_helper'

class UnifiedGattFixture
  attr_reader :writes, :closed, :subscriptions

  def initialize(final: "OK\n")
    @writes = []
    @notifications = []
    @subscriptions = []
    @command = +''
    @binary = false
    @received = 0
    @final = final
  end

  def subscribe(uuid:)
    @subscriptions << uuid
  end

  def write(uuid:, bytes:, response:)
    raise 'must subscribe before writing' if @subscriptions.empty?
    raise 'unconsumed ACK' unless @notifications.empty?

    @writes << { uuid: uuid, bytes: bytes, response: response }
    if @binary
      @received += bytes.bytesize
      @notifications << (@received == @size ? @final : "ACK\n")
    else
      @command << bytes
      if @command.end_with?("\n")
        if @command == "VERSION\n"
          @notifications << "OK 1 2.7.0 3 v1.0\n"
        else
          @size = @command.split[1].to_i
          @notifications << "ERASING\nOK\n"
          @binary = true
        end
        @command.clear
      end
    end
    bytes.bytesize
  end

  def notification(timeout:)
    raise ArgumentError, 'timeout must be positive' unless timeout.positive?
    raise Timeout::Error, 'silent GATT' if @notifications.empty?

    { uuid: Meshtastic::Admin::Firmware::BLE::TX_UUID, bytes: @notifications.shift }
  end

  def close
    @closed = true
  end
end

describe 'Firmware selected-device BlueZ GATT' do
  it 'scopes writes and notification matches to the selected device without requiring bootloader pairing' do
    klass = Meshtastic::Admin::Firmware::BLE.const_get(:BlueZ)
    service = Meshtastic::Admin::Firmware::BLE::SERVICE_UUID
    uuid = Meshtastic::Admin::Firmware::BLE::TX_UUID
    device = '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF'
    objects = {
      '/org/bluez/hci0' => { 'org.bluez.Adapter1' => { 'Powered' => true } },
      '/other/s' => { 'org.bluez.GattService1' => { 'Device' => '/other', 'UUID' => service } },
      '/other/c' => { 'org.bluez.GattCharacteristic1' => { 'Service' => '/other/s', 'UUID' => uuid } },
      device => { 'org.bluez.Device1' => { 'Address' => 'AA:BB:CC:DD:EE:FF', 'Adapter' => '/org/bluez/hci0', 'ServicesResolved' => true, 'Connected' => true, 'Paired' => false } },
      "#{device}/s" => { 'org.bluez.GattService1' => { 'Device' => device, 'UUID' => service } },
      "#{device}/s/c" => { 'org.bluez.GattCharacteristic1' => { 'Service' => "#{device}/s", 'UUID' => uuid } }
    }
    socket, peer = UNIXSocket.pair
    queue = DBus::MessageQueue.allocate
    queue.instance_variable_set(:@socket, socket)
    queue.instance_variable_set(:@buffer, +''.b)
    queue.instance_variable_set(:@read_buffer, +''.b)
    queue.instance_variable_set(:@mutex, Mutex.new)
    bus = double('private bus', message_queue: queue)
    calls = []
    signal_handler = nil
    allow(bus).to receive(:process) { |message| signal_handler.call(message) }
    allow(DBus::ASystemBus).to receive(:allocate).and_return(bus)
    allow(bus).to receive(:initialize)
    allow(bus).to receive(:add_match) do |rule, &handler|
      expect(rule.to_s).to include("path='#{device}/s/c'")
      signal_handler = handler
    end
    allow(bus).to receive(:send_sync_or_async) do |message|
      calls << message
      case message.member
      when 'GetManagedObjects' then [objects]
      when 'GetAll' then [objects.fetch(message.path).fetch(message.params.first.last)]
      when 'WriteValue'
        signal = DBus::Message.new(DBus::Message::SIGNAL)
        signal.path = "#{device}/s/c"
        signal.interface = 'org.freedesktop.DBus.Properties'
        signal.member = 'PropertiesChanged'
        signal.add_param('s', 'org.bluez.GattCharacteristic1')
        signal.add_param('a{sv}', { 'Value' => ['ay', [79, 75, 10]] })
        signal.add_param('as', [])
        peer.write(signal.marshall)
        []
      else []
      end
    end
    backend = klass.new(address: 'AA:BB:CC:DD:EE:FF', service_uuid: service, timeout: 0.1).connect
    backend.subscribe(uuid: uuid)
    backend.write(uuid: uuid, bytes: 'abc', response: true)
    expect(backend.notification(timeout: 0.1)).to eq(uuid: uuid, bytes: "OK\n")
    expect(calls.select { |m| m.member == 'WriteValue' }.map(&:path)).to eq(["#{device}/s/c"])
    expect(calls.map(&:member)).not_to include('Pair', 'StartDiscovery')
    objects.delete("#{device}/s/c")
    expect { backend.write(uuid: uuid, bytes: 'must not reach decoy', response: false) }.to raise_error(IOError, /selected device/)
    expect { backend.notification(timeout: 0.01) }.to raise_error(IOError, /notification timed out/)
    backend.close
    expect(socket).to be_closed
  ensure
    socket&.close unless socket&.closed?
    peer&.close
  end
end

describe 'Unified BLE firmware installation' do
  it 'rejects another protocol in the direct BLE helper before touching GATT' do
    backend = UnifiedGattFixture.new
    expect do
      Meshtastic::Admin::Firmware::BLE.install(protocol: :legacy_ble, backend: backend, bytes: 'abc')
    end.to raise_error(ArgumentError, /protocol/)
    expect(backend.writes).to be_empty
  end

  it 'uses the selected-address BlueZ backend by default' do
    backend = UnifiedGattFixture.new
    expect(Meshtastic::Admin::Firmware::BLE::BlueZ).to receive(:new)
      .with(address: 'AA:BB:CC:DD:EE:FF', adapter: 'hci0', timeout: 120, service_uuid: Meshtastic::Admin::Firmware::BLE::SERVICE_UUID)
      .and_return(backend)
    expect(backend).to receive(:connect).and_return(backend)
    expect(Meshtastic::Admin::Firmware.install(protocol: :unified_ble, address: 'AA:BB:CC:DD:EE:FF', bytes: 'abc')[:status]).to eq(:verified)
  end

  it 'validates timeout and unknown options before any BLE command' do
    [{ timeout: 0 }, { timeout: Float::INFINITY }, { to: '!aabbccdd' }, { chunk_size: 512 }].each do |invalid|
      backend = UnifiedGattFixture.new
      expect do
        Meshtastic::Admin::Firmware.install({ protocol: :unified_ble, backend: backend, bytes: 'abc' }.merge(invalid))
      end.to raise_error(ArgumentError)
      expect(backend.writes).to be_empty
    end
  end

  it 'never treats ACK, ERR or disconnect as final completion or retries image bytes' do
    ["ACK\n", "ERR Hash Mismatch\n", nil].each do |final|
      backend = UnifiedGattFixture.new(final: final)
      expect do
        Meshtastic::Admin::Firmware.install(protocol: :unified_ble, backend: backend, bytes: 'abc')
      end.to raise_error(IOError)
      expect(backend.writes.count { |w| w[:bytes] == 'abc' }).to eq(1)
      expect(backend.closed).to be true
    end
  end

  it 'fragments commands to ATT size and waits for ACK per data chunk and final OK' do
    backend = UnifiedGattFixture.new
    result = Meshtastic::Admin::Firmware.install(protocol: :unified_ble, backend: backend, bytes: 'x' * 45)
    expect(result).to include(status: :verified, bytes: 45, sha256: Digest::SHA256.hexdigest('x' * 45))
    expect(backend.writes.map { |write| write[:bytes].bytesize }.max).to be <= 20
    expect(backend.writes.map { |write| write[:bytes] }.join).to eq("VERSION\nOTA 45 #{Digest::SHA256.hexdigest('x' * 45)}\n#{'x' * 45}")
    expect(backend.closed).to be true
  end
end
