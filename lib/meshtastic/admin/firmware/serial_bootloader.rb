# frozen_string_literal: true

require 'digest'
require 'timeout'
require 'uart'

module Meshtastic
  module Admin
    module Firmware
      # Native ROM protocol only: never uploads an executable flasher stub.
      module SerialBootloader
        CHIP_IDS = { esp32: 0, esp32s3: 9, esp32c3: 5 }.freeze

        public_class_method def self.install(opts = {})
          bytes = validate(opts.merge({}))
          chip = opts.fetch(:chip)
          offset = opts.fetch(:offset)
          port = UART.open(opts.fetch(:port), 115_200, '8N1')
          attrs = Termios.tcgetattr(port)
          attrs.cflag &= ~(Termios::CRTSCTS | Termios::HUPCL)
          Termios.tcsetattr(port, Termios::TCSANOW, attrs)
          reset_lines(io: port, bootloader: true) if opts.fetch(:reset, :classic) == :classic
          context = { io: port, timeout: opts.fetch(:timeout, 120) }
          synchronize(context.merge({}))
          identify(context.merge(chip: chip))

          command(context.merge(op: 13, payload: [0, 0].pack('V2')))
          command(context.merge(op: 11, payload: [0, opts.fetch(:flash_size), 65_536, 4096, 256, 65_535].pack('V6')))
          blocks = (bytes.bytesize + 1023) / 1024
          params = [bytes.bytesize, blocks, 1024, offset]
          params << 0 unless chip == :esp32
          command(context.merge(op: 2, payload: params.pack('V*')))
          blocks.times do |sequence|
            block = bytes.byteslice(sequence * 1024, 1024).ljust(1024, "\xff".b)
            payload = [1024, sequence, 0, 0].pack('V4') + block
            command(context.merge(op: 3, payload: payload, checksum: block.bytes.reduce(0xef, :^)))
          end
          md5 = command(context.merge(op: 19, payload: [offset, bytes.bytesize, 0, 0].pack('V4'), response_size: 32)).fetch(:data)
          raise IOError, 'ROM flash MD5 mismatch' unless md5.downcase == Digest::MD5.hexdigest(bytes)

          command(context.merge(op: 4, payload: [0].pack('V')))
          reset_lines(io: port, bootloader: false) if opts.fetch(:reset, :classic) == :classic
          { status: :verified, chip: chip, bytes: bytes.bytesize, offset: offset, md5: md5.downcase, sha256: Digest::SHA256.hexdigest(bytes), reboot_requested: true, boot_verified: false }
        ensure
          port&.close
        end

        private_class_method def self.synchronize(opts = {})
          attempts = 0
          begin
            attempts += 1
            response = command(opts.merge(op: 8, payload: "\x07\x07\x12\x20".b + ("\x55" * 32), timeout: [opts.fetch(:timeout), 1].min))
            raise IOError, 'Flasher stub detected; reset into ROM first' if response.fetch(:value).zero?
          rescue Timeout::Error
            raise if attempts >= 3

            retry
          end
        end

        private_class_method def self.identify(opts = {})
          if opts.fetch(:chip) == :esp32
            magic = command(opts.merge(op: 10, payload: [0x40001000].pack('V'))).fetch(:value)
            raise IOError, 'Connected chip is not ESP32' unless magic == 0x00f01d83

            crypt = command(opts.merge(op: 10, payload: [0x3ff5a000].pack('V'))).fetch(:value)
            secure = command(opts.merge(op: 10, payload: [0x3ff5a018].pack('V'))).fetch(:value)
            raise IOError, 'Secure boot/encrypted flash is unsupported' unless crypt.nobits?(0x7f << 20) && secure.nobits?(0x30)
          else
            info = command(opts.merge(op: 20, response_size: 20)).fetch(:data)
            raise IOError, 'Connected chip ID does not match selected chip' unless info.byteslice(12, 4).unpack1('V') == CHIP_IDS.fetch(opts.fetch(:chip))
            raise IOError, 'Secure boot/encrypted flash/secure download is unsupported' unless info.unpack1('V').nobits?(5) && info.getbyte(4).zero?
          end
        end

        private_class_method def self.reset_lines(opts = {})
          io = opts.fetch(:io)
          bootloader = opts.fetch(:bootloader)
          io.ioctl(Termios::TIOCMBIC, [Termios::TIOCM_DTR].pack('i')) if bootloader
          io.ioctl(Termios::TIOCMBIS, [Termios::TIOCM_RTS].pack('i'))
          sleep 0.1
          io.ioctl(Termios::TIOCMBIS, [Termios::TIOCM_DTR].pack('i')) if bootloader
          io.ioctl(Termios::TIOCMBIC, [Termios::TIOCM_RTS].pack('i'))
          return unless bootloader

          sleep 0.05
          io.ioctl(Termios::TIOCMBIC, [Termios::TIOCM_DTR].pack('i'))
        end

        private_class_method def self.validate(opts = {})
          allowed = %i[protocol port chip bytes firmware offset flash_size reset timeout]
          raise ArgumentError, 'Unsupported serial bootloader options' unless (opts.keys - allowed).empty?
          raise ArgumentError, 'protocol must be :esp_rom' unless opts.fetch(:protocol, :esp_rom) == :esp_rom
          raise ArgumentError, 'chip must be :esp32, :esp32s3 or :esp32c3' unless CHIP_IDS.key?(opts[:chip])
          raise ArgumentError, 'port must be a nonempty device path' unless opts[:port].is_a?(String) && !opts[:port].strip.empty?
          raise ArgumentError, 'reset must be :classic or :none' unless %i[classic none].include?(opts.fetch(:reset, :classic))

          timeout = opts.fetch(:timeout, 120)
          raise ArgumentError, 'timeout must be finite and positive' unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?

          capacity = opts[:flash_size]
          raise ArgumentError, 'flash_size must be a power of two from 1 MiB to 16 MiB' unless capacity.is_a?(Integer) && (1_048_576..16_777_216).cover?(capacity) && capacity.nobits?(capacity - 1)

          offset = opts[:offset]
          raise ArgumentError, 'offset must be an application address >= 0x10000 aligned to 0x1000' unless offset.is_a?(Integer) && offset >= 0x10000 && (offset % 4096).zero?
          raise ArgumentError, 'provide exactly one of bytes or firmware' unless opts.key?(:bytes) ^ opts.key?(:firmware)

          bytes = opts.key?(:bytes) ? opts[:bytes] : File.binread(opts.fetch(:firmware))
          raise ArgumentError, 'image must be nonempty binary String' unless bytes.is_a?(String) && !bytes.empty?
          raise ArgumentError, 'image erase range exceeds flash_size' if offset + ((bytes.bytesize + 4095) / 4096 * 4096) > capacity

          validate_image(bytes: bytes.b, chip_id: CHIP_IDS.fetch(opts[:chip]))
          bytes.b
        end

        private_class_method def self.validate_image(opts = {})
          bytes = opts.fetch(:bytes)
          raise ArgumentError, 'expected ESP executable image header' unless bytes.bytesize >= 24 && bytes.getbyte(0) == 0xe9 && (1..16).cover?(bytes.getbyte(1))
          raise ArgumentError, 'image chip ID does not match selected chip' unless bytes.byteslice(12, 2).unpack1('v') == opts.fetch(:chip_id)
          raise ArgumentError, 'invalid image digest flag' unless [0, 1].include?(bytes.getbyte(23))

          position = 24
          checksum = 0xef
          bytes.getbyte(1).times do
            raise ArgumentError, 'truncated ESP segment header' if position + 8 > bytes.bytesize

            size = bytes.byteslice(position + 4, 4).unpack1('V')
            position += 8
            raise ArgumentError, 'truncated or unaligned ESP segment' if size % 4 != 0 || position + size > bytes.bytesize

            bytes.byteslice(position, size).each_byte { |byte| checksum ^= byte }
            position += size
          end
          checksum_position = (position / 16 * 16) + 15
          raise ArgumentError, 'ESP image checksum mismatch' unless bytes.getbyte(checksum_position) == checksum

          ending = checksum_position + 1
          if bytes.getbyte(23) == 1
            raise ArgumentError, 'ESP image SHA-256 mismatch' unless bytes.byteslice(ending, 32) == Digest::SHA256.digest(bytes.byteslice(0, ending))

            ending += 32
          end
          raise ArgumentError, 'trailing data: merged, signed and padded images are unsupported' unless bytes.bytesize == ending
        end

        private_class_method def self.command(opts = {})
          io = opts.fetch(:io)
          op = opts.fetch(:op)
          payload = opts.fetch(:payload, ''.b)
          packet = [0, op, payload.bytesize, opts.fetch(:checksum, 0)].pack('CCvV') + payload
          encoded = packet.bytes.map do |byte|
            if byte == 0xc0
              "\xdb\xdc".b
            else
              byte == 0xdb ? "\xdb\xdd".b : byte.chr
            end
          end.join.b
          Timeout.timeout(opts.fetch(:timeout)) do
            io.write("\xc0".b + encoded + "\xc0".b)
            loop do
              reply = read_frame(io: io)
              raise IOError, 'Truncated ROM response' if reply.bytesize < 12

              direction, response_op, length, value = reply.unpack('CCvV')
              raise IOError, 'Invalid ROM response header' unless direction == 1 && length == reply.bytesize - 8
              next if response_op == 8 && op != 8 # ROM sends eight SYNC replies.
              raise IOError, 'Unexpected ROM response opcode' unless response_op == op

              data = reply.byteslice(8..)
              # Error responses may omit the expected MD5/security data.
              status = data.byteslice(-4, 4).bytes
              raise IOError, format('ROM command 0x%<op>02x failed: status=%<status>d error=%<error>d', op: op, status: status[0], error: status[1]) unless status[0].zero?
              raise IOError, 'Invalid ROM response length' unless data.bytesize == opts.fetch(:response_size, 0) + 4

              return { value: value, data: data.byteslice(0, data.bytesize - 4) }
            end
          end
        end

        private_class_method def self.read_frame(opts = {})
          io = opts.fetch(:io)
          frame = +''.b
          started = false
          escaped = false
          loop do
            byte = io.readpartial(1).getbyte(0)
            if byte == 0xc0
              raise IOError, 'Truncated SLIP escape' if escaped
              return frame if started && !frame.empty?

              started = true
            elsif started
              if escaped
                raise IOError, 'Invalid SLIP escape' unless [0xdc, 0xdd].include?(byte)

                frame << (byte == 0xdc ? 0xc0 : 0xdb)
                escaped = false
              elsif byte == 0xdb
                escaped = true
              else
                frame << byte
              end
              raise IOError, 'Oversized ROM response' if frame.bytesize > 4096
            end
          end
        end

        public_class_method def self.authors
          "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n"
        end

        public_class_method def self.help
          puts "USAGE:
            # Install and verify native ESP ROM firmware.
            #{self}.install(
              protocol: 'optional - :esp_rom only; defaults to :esp_rom',
              port: 'required - dedicated UART device path, not an active PhoneAPI connection',
              chip: 'required - :esp32, :esp32s3 or :esp32c3; UART ROM only',
              bytes: 'optional - raw unmerged application image, exclusive with firmware',
              firmware: 'optional - application .bin file path, exclusive with bytes',
              offset: 'required - known application partition address, >= 0x10000, sector aligned',
              flash_size: 'required - known physical flash capacity, power of two from 1 to 16 MiB',
              reset: 'optional - :classic DTR/RTS reset (default) or :none for manual ROM entry',
              timeout: 'optional - positive command deadline in seconds, default 120'
            )
            # Print author contact information.
            #{self}.authors
          "
        end
      end
    end
  end
end
