# frozen_string_literal: true

require 'digest'
require 'securerandom'
require 'tempfile'
require 'timeout'

module Meshtastic
  module Admin
    module Firmware
      # Strict Intel HEX validation and explicitly selected nRF52840 SWD programming.
      module Hex
        MAX_IMAGE = 16 * 1024 * 1024

        public_class_method def self.validate(opts = {})
          raise ArgumentError, 'Only explicit expected_chip: :nrf52840 is supported' unless opts[:expected_chip] == :nrf52840

          bytes = opts[:bytes]
          raise ArgumentError, 'HEX bytes must be a nonempty String of at most 16 MiB' unless bytes.is_a?(String) && bytes.bytesize.between?(1, MAX_IMAGE)

          base = 0
          eof = false
          start = nil
          ranges = []
          bytes.b.each_line do |raw|
            line = raw.delete_suffix("\n").delete_suffix("\r")
            raise ArgumentError, 'Invalid HEX record or data after EOF' if eof || !line.match?(/\A:(?:[0-9a-fA-F]{2}){5,260}\z/)

            fields = [line[1..]].pack('H*').bytes
            count, high, low, type = fields.first(4)
            address = (high << 8) | low
            data = fields[4, count]
            raise ArgumentError, 'HEX length or checksum mismatch' unless fields.length == count + 5 && fields.sum.nobits?(255)

            case type
            when 0
              raise ArgumentError, 'Empty data or record crosses 64 KiB boundary' unless count.positive? && address + count <= 0x10000

              first = base + address
              last = first + count
              raise ArgumentError, 'HEX address outside nRF52840 flash/UICR' unless (first >= 0 && last <= 0x100000) || (first >= 0x10001000 && last <= 0x10002000)

              ranges << [first, last]
            when 1
              raise ArgumentError, 'Malformed EOF record' unless count.zero? && address.zero?

              eof = true
            when 2, 4
              raise ArgumentError, 'Malformed extended address record' unless count == 2 && address.zero?

              base = data.pack('C*').unpack1('n') << (type == 2 ? 4 : 16)
            when 3, 5
              raise ArgumentError, 'Malformed or repeated start address record' unless count == 4 && address.zero? && start.nil?

              start = if type == 3
                        segment, offset = data.pack('C*').unpack('n2')
                        (segment << 4) + offset
                      else
                        data.pack('C*').unpack1('N')
                      end
              raise ArgumentError, 'Start address outside flash' unless start < 0x100000
            else
              raise ArgumentError, "Unsupported HEX record type #{type}"
            end
          end
          raise ArgumentError, 'HEX requires EOF and nonempty data' unless eof && !ranges.empty?

          ranges.sort_by!(&:first)
          raise ArgumentError, 'Overlapping HEX data records' if ranges.each_cons(2).any? { |left, right| left.last > right.first }

          { data_bytes: ranges.sum { |first, last| last - first }, ranges: ranges, start_address: start }
        end

        public_class_method def self.install(opts = {})
          allowed = %i[protocol firmware bytes expected_chip expected_target openocd interface_config target_config timeout]
          raise ArgumentError, 'Unsupported HEX install options' unless (opts.keys - allowed).empty?
          raise ArgumentError, 'protocol must be explicitly :swd' unless opts[:protocol] == :swd
          raise ArgumentError, 'Supply exactly one of firmware or bytes' unless opts.key?(:firmware) ^ opts.key?(:bytes)

          bytes = image_bytes(opts.merge({}))
          metadata = validate(bytes: bytes, expected_chip: opts[:expected_chip])
          target = opts[:expected_target]
          raise ArgumentError, 'expected_target must be an explicit OpenOCD target name' unless target.is_a?(String) && target.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z/)

          executable = trusted_file(path: opts[:openocd], executable: true)
          interface = trusted_file(path: opts[:interface_config])
          config = trusted_file(path: opts[:target_config])
          timeout = opts.fetch(:timeout, 120)
          raise ArgumentError, 'timeout must be finite and positive (at most 3600 seconds)' unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive? && timeout <= 3600

          token = "MESHTASTIC_HEX_OK_#{SecureRandom.hex(16)}"
          Tempfile.create(['meshtastic-', '.hex']) do |image|
            image.binmode
            image.write(bytes)
            image.flush
            path = tcl_word(value: image.path)
            script = <<~TCL
              if {[catch {
                init
                targets #{tcl_word(value: target)}
                reset init
                halt
                if {[lindex [read_memory 0x10000100 32 1] 0] != 0x52840} {error "nRF52840 FICR PART mismatch"}
                if {[lindex [read_memory 0x10000010 32 1] 0] != 4096 || [lindex [read_memory 0x10000014 32 1] 0] != 256} {error "nRF52840 flash geometry mismatch"}
                flash write_image erase #{path} 0 ihex
                verify_image #{path} 0 ihex
                reset run
              } failure]} {
                echo $failure
                shutdown error
              } else {
                echo #{token}
                shutdown
              }
            TCL
            args = [executable, '-c', 'gdb_port disabled; telnet_port disabled; tcl_port disabled',
                    '-f', interface, '-c', 'transport select swd', '-f', config, '-c', script]
            run_programmer(args: args, timeout: timeout, token: token)
          end
          metadata.merge(status: :verified, protocol: :swd, format: :hex, expected_chip: opts[:expected_chip],
                         expected_target: target, bytes: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes),
                         flash_verified: true, reboot_verified: false)
        end

        private_class_method def self.image_bytes(opts = {})
          return opts[:bytes].b.dup.freeze if opts[:bytes].is_a?(String)
          return opts[:bytes] unless opts.key?(:firmware)

          path = opts[:firmware]
          raise ArgumentError, 'firmware must name a regular HEX file' unless path.is_a?(String) && File.file?(path)

          File.open(path, File::RDONLY | File::NONBLOCK) do |file|
            raise ArgumentError, 'firmware must be a bounded regular file' unless file.stat.file? && file.stat.size <= MAX_IMAGE

            file.binmode
            file.read(MAX_IMAGE + 1).freeze
          end
        end

        private_class_method def self.trusted_file(opts = {})
          path = opts[:path]
          raise ArgumentError, 'Supply absolute paths to installed OpenOCD and trusted configuration files' unless path.is_a?(String) && path.start_with?('/') && !path.match?(/[\x00-\x1f\x7f]/) && File.file?(path) && File.readable?(path)
          raise ArgumentError, 'openocd must be an executable file' if opts[:executable] && !File.executable?(path)

          path
        end

        private_class_method def self.tcl_word(opts = {})
          escaped = opts.fetch(:value).gsub(/[\\"\[\]${}\r\n]/) { |character| { "\r" => '\r', "\n" => '\n' }.fetch(character) { "\\#{character}" } }
          "\"#{escaped}\""
        end

        private_class_method def self.run_programmer(opts = {})
          Tempfile.create('meshtastic-openocd-log') do |log|
            pid = Process.spawn(*opts.fetch(:args), in: File::NULL, out: log, err: log, pgroup: true)
            begin
              _, status = Timeout.timeout(opts.fetch(:timeout)) { Process.wait2(pid) }
            rescue Timeout::Error
              begin
                Process.kill('KILL', -pid)
              rescue Errno::ESRCH
                nil
              end
              begin
                Process.wait(pid)
              rescue Errno::ECHILD
                nil
              end
              raise IOError, 'OpenOCD timed out; flash state is uncertain; do not automatically retry'
            end
            log.rewind
            completed = log.each_line.any? { |line| line.strip == opts.fetch(:token) }
            raise IOError, "OpenOCD failed or did not complete verification/reset (exit #{status.exitstatus.inspect}); flash state may be partial" unless status.success? && completed
          end
        rescue Errno::ENOENT, Errno::EACCES => e
          raise IOError, "Unable to execute installed OpenOCD: #{e.message}"
        end

        public_class_method def self.authors
          'Meshtastic Ruby contributors'
        end

        public_class_method def self.help
          puts <<~HELP
            Validate Intel HEX without accessing hardware.
            #{self}.validate(
              bytes: 'required - complete Intel HEX content',
              expected_chip: 'required - exact supported symbol :nrf52840'
            )
            Program and verify explicitly selected nRF52840 hardware (destructive).
            #{self}.install(
              protocol: 'required - explicitly :swd only',
              firmware: 'optional - path to HEX file, exclusive with bytes',
              bytes: 'optional - Intel HEX content, exclusive with firmware',
              expected_chip: 'required - exact supported symbol :nrf52840',
              expected_target: 'required - configured OpenOCD target name, e.g. nrf52.cpu',
              openocd: 'required - absolute path to trusted installed executable',
              interface_config: 'required - absolute path to trusted probe Tcl configuration',
              target_config: 'required - absolute path to trusted nRF52 Tcl configuration',
              timeout: 'optional - positive execution limit in seconds, default 120'
            )
            List the module contributors.
            #{self}.authors
          HELP
        end
      end
    end
  end
end
