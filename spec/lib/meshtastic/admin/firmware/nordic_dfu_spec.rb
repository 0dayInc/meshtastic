# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'zlib'
require 'meshtastic/admin/firmware/nordic_dfu' if File.exist?(File.expand_path('../../../../../lib/meshtastic/admin/firmware/nordic_dfu.rb', __dir__))

# A stateful byte-level peer, not canned success responses. It enforces the
# SDK11 command order, image sizing, PRN cadence, and independent image CRC.
class NordicDFUPeer
  CONTROL = '00001531-1212-efde-1523-785feabcd123'
  PACKET = '00001532-1212-efde-1523-785feabcd123'
  attr_reader :image, :activated, :closed, :writes
  attr_accessor :fault

  def initialize
    @state = :idle
    @events = []
    @image = ''.b
    @init = ''.b
    @writes = []
    @count = 0
  end

  def subscribe(uuid:)
    raise 'wrong subscription' unless uuid == CONTROL

    @subscribed = true
  end

  def write(uuid:, bytes:, response:)
    raise 'not subscribed' unless @subscribed

    @writes << [uuid, bytes, response]
    if uuid == CONTROL
      raise 'control requires write response' unless response

      control(bytes)
    else
      raise 'invalid packet write' unless uuid == PACKET && !response && bytes.bytesize <= 20

      packet(bytes)
    end
  end

  def control(bytes)
    case [@state, bytes.bytes]
    when [:idle, [1, 4]] then @state = :size
    when [:started, [2, 0]] then @state = :init
    when [:init, [2, 1]]
      raise 'bad init' unless @init.bytesize == 14 && @init.unpack1('v') == 0x52

      reply(2)
      @state = :initialized
    when [:ready, [3]] then @state = :image
    when [:received, [4]]
      @image.setbyte(0, @image.getbyte(0) ^ 1) if @fault == :flash_corruption
      reply(4, crc(@image) == @init.byteslice(-2, 2).unpack1('v') ? 1 : 5)
      @state = :validated
    when [:validated, [5]] then @activated = true
    else
      raise "unexpected command #{@state}: #{bytes.bytes}" unless @state == :initialized && bytes.getbyte(0) == 8 && bytes.bytesize == 3

      @interval = bytes.byteslice(1, 2).unpack1('v')
      raise 'receipts disabled' unless @interval.positive?

      @state = :ready
    end
  end

  def packet(bytes)
    case @state
    when :size
      sd, bl, @size = bytes.unpack('V3')
      raise 'bad image sizes' unless bytes.bytesize == 12 && sd.zero? && bl.zero? && @size.positive?

      @state = :started
      reply(1)
    when :init then @init << bytes
    when :image
      raise 'unaligned image packet' unless (bytes.bytesize % 4).zero?

      @image << bytes
      raise 'image overflow' if @image.bytesize > @size

      @count += 1
      if @image.bytesize == @size
        @state = :received
        reply(3)
      elsif (@count % @interval).zero?
        receipt = @image.bytesize + (@fault == :receipt ? 4 : 0)
        @events << [17, receipt].pack('CV')
      end
    else raise "packet in #{@state}"
    end
  end

  def reply(opcode, status = 1)
    status = 6 if @fault == :reject && opcode == 2
    opcode = 4 if @fault == :wrong_opcode && opcode == 1
    @events << [16, opcode, status].pack('C*')
  end

  def notification(timeout:)
    raise 'unbounded wait' unless timeout.positive?
    return nil if @fault == :timeout

    bytes = @events.shift
    raise 'client waited when peer owes no response' unless bytes

    { uuid: CONTROL, bytes: bytes }
  end

  def close
    @closed = true
  end

  def crc(bytes)
    crc = 0xffff
    bytes.each_byte do |byte|
      crc ^= byte << 8
      8.times { crc = ((crc << 1) ^ (crc.anybits?(0x8000) ? 0x1021 : 0)) & 0xffff }
    end
    crc
  end
end

RSpec.describe 'Meshtastic::Admin::Firmware::NordicDFU' do
  let(:installer) { Meshtastic::Admin::Firmware::NordicDFU }
  let(:peer) { NordicDFUPeer.new }
  let(:image) { (0...244).to_a.pack('C*') }
  let(:init) { [0x52, 0xffff, 1, 1, 0xfffe, peer.crc(image)].pack('vvVvvv') }
  let(:manifest) { { manifest: { application: { bin_file: 'app.bin', dat_file: 'app.dat' } } } }
  let(:entries) { { 'manifest.json' => JSON.generate(manifest), 'app.bin' => image, 'app.dat' => init } }

  def zip(entries, compression: 0)
    local = ''.b
    central = ''.b
    entries.each do |name, bytes|
      raw = if compression == 8
              deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
              begin
                deflater.deflate(bytes, Zlib::FINISH)
              ensure
                deflater.close
              end
            else
              bytes
            end
      crc = Zlib.crc32(bytes)
      central << [0x02014b50, 20, 20, 0, compression, 0, 0, crc, raw.bytesize, bytes.bytesize,
                  name.bytesize, 0, 0, 0, 0, 0, local.bytesize].pack('VvvvvvvVVVvvvvvVV') << name
      local << [0x04034b50, 20, 0, compression, 0, 0, crc, raw.bytesize, bytes.bytesize,
                name.bytesize, 0].pack('VvvvvvVVVvv') << name << raw
    end
    local + central + [0x06054b50, 0, 0, entries.length, entries.length, central.bytesize, local.bytesize, 0].pack('VvvvvVVv')
  end

  {
    'image CRC mismatch' => ->(entries) { entries.merge('app.bin' => 'x' * 244) },
    'unaligned image' => ->(entries) { entries.merge('app.bin' => 'x') },
    'empty image' => ->(entries) { entries.merge('app.bin' => '') },
    'signed extension' => ->(entries) { entries.merge('app.dat' => entries.fetch('app.dat').byteslice(0, 12) + [2, 244].pack('V2') + ('x' * 96)) },
    'secure protobuf init' => ->(entries) { entries.merge('app.dat' => "\x12\x08\x0a\x06secure".b) },
    'bootloader update' => ->(entries) { entries.merge('manifest.json' => JSON.generate(manifest: { bootloader: { bin_file: 'app.bin', dat_file: 'app.dat' } })) },
    'traversal entry' => ->(entries) { entries.merge('../outside' => 'unsafe') },
    'missing init' => ->(entries) { entries.except('app.dat') }
  }.each do |description, mutate|
    it "rejects #{description} before any bootloader writes" do
      expect { installer.install(package_bytes: zip(mutate.call(entries)), gatt: peer) }.to raise_error(ArgumentError)
      expect(peer.writes).to be_empty
    end
  end

  it 'rejects truncated ZIP data without writing to the bootloader' do
    expect { installer.install(package_bytes: zip(entries).byteslice(0, 100), gatt: peer) }.to raise_error(ArgumentError)
    expect(peer.writes).to be_empty
  end

  it 'reads a package file without requiring any external unpacker' do
    require 'tempfile'
    Tempfile.create(['nordic', '.zip']) do |file|
      file.binmode
      file.write(zip(entries))
      file.flush
      installer.install(package: file.path, gatt: peer)
      expect(peer.activated).to be(true)
    end
  end

  it 'rejects ambiguous package sources before touching GATT' do
    expect { installer.install(package_bytes: zip(entries), package: '/unused.zip', gatt: peer) }.to raise_error(ArgumentError, /exactly one/)
    expect(peer.writes).to be_empty
  end

  it 'rejects unknown options rather than ignoring secure or retry requests' do
    expect { installer.install(package_bytes: zip(entries), gatt: peer, secure: true) }.to raise_error(ArgumentError, /Unsupported.*secure/)
    expect(peer.writes).to be_empty
  end

  it 'rejects a JSON scalar manifest with an operator-usable error' do
    malformed = entries.merge('manifest.json' => JSON.generate('not a manifest'))
    expect { installer.install(package_bytes: zip(malformed), gatt: peer) }.to raise_error(ArgumentError, /manifest/)
    expect(peer.writes).to be_empty
  end

  it 'rejects malformed manifest application types clearly before I/O' do
    malformed = entries.merge('manifest.json' => JSON.generate(manifest: { application: 'oops' }))
    expect { installer.install(package_bytes: zip(malformed), gatt: peer) }.to raise_error(ArgumentError, /application/)
    expect(peer.writes).to be_empty
  end

  %i[receipt reject wrong_opcode timeout flash_corruption].each do |fault|
    it "fails closed on #{fault} without replaying unsequenced packets" do
      peer.fault = fault
      expect { installer.install(package_bytes: zip(entries), gatt: peer) }.to raise_error(fault == :timeout ? Timeout::Error : IOError)
      expect(peer.activated).not_to be(true)
      expect(peer.closed).to be(true)
      expect(peer.writes.count { |_uuid, bytes, _response| bytes == [1, 4].pack('C*') }).to eq(1)
    end
  end

  it 'connects the shared production BlueZ backend to the legacy service by default' do
    require 'meshtastic/admin/firmware/ble'
    expect(Meshtastic::Admin::Firmware::BLE::BlueZ).to receive(:new).with(
      address: 'AA:BB:CC:DD:EE:FF', adapter: 'hci0', timeout: 30,
      service_uuid: '00001530-1212-efde-1523-785feabcd123'
    ).and_return(peer)
    expect(peer).to receive(:connect).and_return(peer)
    installer.install(package_bytes: zip(entries), address: 'AA:BB:CC:DD:EE:FF')
    expect(peer.activated).to be(true)
  end

  it 'reads a deflated ZIP generated by normal DFU package tools' do
    installer.install(package_bytes: zip(entries, compression: 8), gatt: peer)
    expect(peer.image).to eq(image)
    expect(peer.activated).to be(true)
  end

  it 'installs a legacy application ZIP through real command and receipt states' do
    expect(defined?(Meshtastic::Admin::Firmware::NordicDFU)).to eq('constant')
    result = installer.install(package_bytes: zip(entries), gatt: peer)
    expect(peer.image).to eq(image)
    expect(peer.activated).to be(true)
    expect(peer.closed).to be(true)
    expect(result).to include(status: :verified, bytes: image.bytesize, protocol: :nordic_dfu, reboot_verified: false)
  end
end
