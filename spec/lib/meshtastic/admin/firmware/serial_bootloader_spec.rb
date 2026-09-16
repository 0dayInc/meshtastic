# frozen_string_literal: true

require 'spec_helper'
require 'pty'
require 'digest'
require 'timeout'
require 'tempfile'
require 'meshtastic/admin/firmware/serial_bootloader'

RSpec.describe Meshtastic::Admin::Firmware::SerialBootloader do # rubocop:disable Metrics/BlockLength
  def image(chip_id = 0)
    header = [0xe9, 1, 2, 0x20, 0x40000000].pack('C4V')
    header << [0xee, 0, 0, 0, chip_id, 0, 0, 0].pack('C4vCvv') << "\0\0\0\0\1".b
    data = ("\xc0\xdb".b * 600)
    body = header + [0x3ffb0000, data.bytesize].pack('V2') + data
    body << "\0" until body.bytesize % 16 == 15
    body << [data.bytes.reduce(0xef, :^)].pack('C')
    body + Digest::SHA256.digest(body)
  end

  def frame(packet)
    "\xc0".b + packet.bytes.map { |b|
      if b == 0xc0
        "\xdb\xdc".b
      else
        b == 0xdb ? "\xdb\xdd".b : b.chr
      end
    }.join.b + "\xc0".b
  end

  def receive_packet(io)
    bytes = +''.b
    started = false
    loop do
      b = io.readpartial(1).getbyte(0)
      if b == 0xc0
        return bytes.gsub("\xdb\xdc".b, "\xc0".b).gsub("\xdb\xdd".b, "\xdb".b) if started && !bytes.empty?

        started = true
      elsif started
        bytes << b
      end
    end
  end

  def emulate(bytes:, chip_id: 0, failure: nil)
    PTY.open do |master, slave|
      commands = []
      flash = +''.b
      worker = Thread.new do
        Thread.current.report_on_exception = false
        loop do
          packet = receive_packet(master)
          direction, op, length, checksum = packet.unpack('CCvV')
          payload = packet.byteslice(8..)
          raise 'bad request framing' unless direction.zero? && length == payload.bytesize

          commands << op
          value = 0
          response = +''.b
          case op
          when 8
            raise 'bad sync' unless payload == "\x07\x07\x12\x20".b + ("\x55" * 32)

            value = failure == :stub ? 0 : 0x20100707
            next if failure == :sync_once && commands.count(8) == 1
          when 10
            address = payload.unpack1('V')
            value = address == 0x40001000 ? 0x00f01d83 : 0
            value = 0 if failure == :wrong_chip
            value = 0x30 if failure == :secure && address == 0x3ff5a018
          when 0x14
            response = ([failure == :secure ? 1 : 0] + ([0] * 8) + [failure == :wrong_chip ? 99 : chip_id, 0]).pack('VC8V2')
          when 0x0d
            raise 'bad attach' unless payload == [0, 0].pack('V2')
          when 0x0b
            raise 'bad geometry' unless payload == [0, 4 * 1024 * 1024, 65_536, 4096, 256, 65_535].pack('V6')
          when 2
            params = payload.unpack('V*')
            expected = [bytes.bytesize, (bytes.bytesize + 1023) / 1024, 1024, 0x10000]
            expected << 0 unless chip_id.zero?
            raise "bad begin #{params}" unless params == expected
          when 3
            size, sequence, reserved1, reserved2 = payload.unpack('V4')
            block = payload.byteslice(16..)
            raise 'bad block' unless size == 1024 && block.bytesize == size && sequence * 1024 == flash.bytesize && reserved1.zero? && reserved2.zero?
            raise 'bad checksum' unless checksum == block.bytes.reduce(0xef, :^)

            flash << block
          when 0x13
            raise 'bad verify range' unless payload == [0x10000, bytes.bytesize, 0, 0].pack('V4')
            raise 'different flashed bytes' unless flash.byteslice(0, bytes.bytesize) == bytes

            response = failure == :digest ? '0' * 32 : Digest::MD5.hexdigest(flash.byteslice(0, bytes.bytesize))
          when 4
            raise 'bad end' unless payload == [0].pack('V')
          else
            raise "unexpected opcode #{op}"
          end
          status = failure == op ? [1, 5, 0, 0].pack('C4') : "\0" * 4
          response += status
          reply = frame([1, op, response.bytesize, value].pack('CCvV') + response)
          if op == 3
            next if failure == :silent

            reply = "\xc0\xdb\x01\xc0".b if failure == :bad_escape
            reply = frame([1, 99, 4, 0].pack('CCvV') + ("\0" * 4)) if failure == :wrong_opcode
            reply = frame([1, op, 99, 0].pack('CCvV') + ("\0" * 4)) if failure == :bad_length
            reply = frame('short') if failure == :short
          end
          (op == 8 ? 8 : 1).times { master.write(reply) }
          break if op == 4 || failure == op || (op == 0x13 && failure == :digest)
        end
      rescue EOFError, Errno::EIO
        nil
      end
      begin
        yield slave.path, commands
      ensure
        worker.kill
        worker.join
        worker.value
      end
    end
  end

  let(:installer) { Meshtastic::Admin::Firmware::SerialBootloader }
  let(:bytes) { image }

  it 'rejects invalid chip, image, flash geometry and options before opening any port' do
    base = { port: '/dev/never-open', chip: :esp32, bytes: bytes, offset: 0x10000, flash_size: 4 * 1024 * 1024, reset: :none }
    corrupt = bytes.dup
    corrupt.setbyte(35, corrupt.getbyte(35) ^ 1)
    corrupt_hash = bytes.dup
    corrupt_hash.setbyte(-1, corrupt_hash.getbyte(-1) ^ 1)
    invalid = [
      { chip: :esp8266 }, { bytes: 'bad' }, { bytes: image(9) }, { bytes: corrupt },
      { bytes: corrupt_hash },
      { bytes: "#{bytes}junk" }, { bytes: bytes.byteslice(0, 35) },
      { offset: -1 }, { offset: 0x10001 }, { offset: 0 }, { offset: 4 * 1024 * 1024 },
      { flash_size: 123 }, { timeout: 0 }, { timeout: Float::INFINITY },
      { reset: :magic }, { protocol: :nordic_serial }, { firmware: '/tmp/ambiguous' },
      { surprise: true }, { port: '' }
    ]
    expect(UART).not_to receive(:open)
    invalid.each do |change|
      expect { installer.install(base.merge(change)) }.to raise_error(ArgumentError), change.inspect
    end
  end

  { esp32s3: 9, esp32c3: 5 }.each do |chip, id|
    it "identifies #{chip} with GET_SECURITY_INFO and uses extended FLASH_BEGIN" do
      firmware = image(id)
      emulate(bytes: firmware, chip_id: id) do |port, commands|
        result = installer.install(port: port, chip: chip, bytes: firmware, offset: 0x10000, flash_size: 4 * 1024 * 1024, reset: :none)
        expect(result[:chip]).to eq(chip)
        expect(commands).to eq([8, 20, 13, 11, 2, 3, 3, 19, 4])
      end
    end
  end

  it 'retries only synchronization when the ROM misses its first request' do
    emulate(bytes: bytes, failure: :sync_once) do |port, commands|
      result = installer.install(port: port, chip: :esp32, bytes: bytes, offset: 0x10000, flash_size: 4 * 1024 * 1024, reset: :none, timeout: 0.1)
      expect(result[:status]).to eq(:verified)
      expect(commands.count(8)).to eq(2)
      expect(commands.count(2)).to eq(1)
    end
  end

  it 'rejects an already running flasher stub before any flash command' do
    emulate(bytes: bytes, failure: :stub) do |port, commands|
      expect { installer.install(port: port, chip: :esp32, bytes: bytes, offset: 0x10000, flash_size: 4 * 1024 * 1024, reset: :none) }.to raise_error(IOError, /stub/)
      expect(commands).to eq([8])
    end
  end

  [3, :digest, :bad_escape, :wrong_opcode, :bad_length, :short, :silent].each do |failure|
    it "fails closed on #{failure} without reboot or replaying FLASH_DATA and closes its UART" do
      opened = nil
      allow(UART).to(receive(:open).and_wrap_original { |original, *args| opened = original.call(*args) })
      emulate(bytes: bytes, failure: failure) do |port, commands|
        error = failure == :silent ? Timeout::Error : IOError
        expect { installer.install(port: port, chip: :esp32, bytes: bytes, offset: 0x10000, flash_size: 4 * 1024 * 1024, reset: :none, timeout: 0.1) }.to raise_error(error)
        expect(commands).not_to include(4)
        expect(commands.count(3)).to eq(failure == :digest ? 2 : 1)
      end
      expect(opened).to be_closed
    end
  end

  { esp32: 0, esp32s3: 9, esp32c3: 5 }.each do |chip, id|
    %i[secure wrong_chip].each do |failure|
      it "rejects #{failure} on #{chip} before erasing any flash" do
        firmware = image(id)
        emulate(bytes: firmware, chip_id: id, failure: failure) do |port, commands|
          expect { installer.install(port: port, chip: chip, bytes: firmware, offset: 0x10000, flash_size: 4 * 1024 * 1024, reset: :none) }.to raise_error(IOError)
          expect(commands).not_to include(2, 3)
        end
      end
    end
  end

  it 'reads an image file and accepts the ESP format without an appended digest' do
    firmware = bytes.byteslice(0, bytes.bytesize - 32)
    firmware.setbyte(23, 0)
    Tempfile.create(['esp-app', '.bin']) do |file|
      file.binmode
      file.write(firmware)
      file.flush
      emulate(bytes: firmware) do |port, _commands|
        result = installer.install(port: port, chip: :esp32, firmware: file.path, offset: 0x10000, flash_size: 4 * 1024 * 1024, reset: :none)
        expect(result[:md5]).to eq(Digest::MD5.hexdigest(firmware))
      end
    end
  end

  it 'clears inherited hardware flow control and hangup reset before writing ROM bytes' do
    allow(UART).to receive(:open).and_wrap_original do |original, *args|
      serial = original.call(*args)
      attrs = Termios.tcgetattr(serial)
      attrs.cflag |= Termios::CRTSCTS | Termios::HUPCL
      Termios.tcsetattr(serial, Termios::TCSANOW, attrs)
      allow(serial).to receive(:write).and_wrap_original do |write, *data|
        expect(Termios.tcgetattr(serial).cflag & (Termios::CRTSCTS | Termios::HUPCL)).to eq(0)
        write.call(*data)
      end
      serial
    end
    emulate(bytes: bytes) do |port, _commands|
      installer.install(port: port, chip: :esp32, bytes: bytes, offset: 0x10000, flash_size: 4 * 1024 * 1024, reset: :none)
    end
  end

  it 'uses classic DTR/RTS boot reset and a final EN pulse on a dedicated UART' do
    controls = []
    opened = nil
    allow(UART).to receive(:open).and_wrap_original do |original, *args|
      opened = original.call(*args)
      allow(opened).to receive(:ioctl) { |op, bits| controls << [op, bits.unpack1('i')] }
      opened
    end
    allow(installer).to receive(:sleep)
    emulate(bytes: bytes) do |port, _commands|
      installer.install(port: port, chip: :esp32, bytes: bytes, offset: 0x10000, flash_size: 4 * 1024 * 1024)
    end
    expect(controls).to eq([
                             [Termios::TIOCMBIC, Termios::TIOCM_DTR], [Termios::TIOCMBIS, Termios::TIOCM_RTS],
                             [Termios::TIOCMBIS, Termios::TIOCM_DTR], [Termios::TIOCMBIC, Termios::TIOCM_RTS],
                             [Termios::TIOCMBIC, Termios::TIOCM_DTR],
                             [Termios::TIOCMBIS, Termios::TIOCM_RTS], [Termios::TIOCMBIC, Termios::TIOCM_RTS]
                           ])
    expect(opened).to be_closed
  end

  it 'opens a real UART PTY, syncs, flashes checksummed blocks and verifies the device MD5 before reboot' do
    emulate(bytes: bytes) do |port, commands|
      result = installer.install(port: port, chip: :esp32, bytes: bytes, offset: 0x10000, flash_size: 4 * 1024 * 1024, reset: :none)
      expect(result).to include(status: :verified, chip: :esp32, bytes: bytes.bytesize, md5: Digest::MD5.hexdigest(bytes), reboot_requested: true, boot_verified: false)
      expect(commands).to eq([8, 10, 10, 10, 13, 11, 2, 3, 3, 19, 4])
    end
  end
end
