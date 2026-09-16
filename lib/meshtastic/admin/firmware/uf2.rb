# frozen_string_literal: true

require 'digest'

module Meshtastic
  module Admin
    module Firmware
      # UF2 mass-storage submission is not a flash verification protocol.
      module UF2
        MAX_IMAGE = 32 * 1024 * 1024

        public_class_method def self.install(opts = {})
          raise ArgumentError, 'protocol must be explicitly :uf2' unless opts[:protocol] == :uf2
          raise ArgumentError, 'Unsupported UF2 install options' unless (opts.keys - %i[protocol firmware bytes mount family_id board_id flash_size]).empty?
          raise ArgumentError, 'Supply exactly one of firmware or bytes' unless opts.key?(:firmware) ^ opts.key?(:bytes)

          bytes = image_bytes(opts.merge({}))
          validate_image(opts.merge(bytes: bytes))
          mount = opts[:mount]
          raise ArgumentError, 'mount must be an explicit canonical absolute bootloader directory' unless mount.is_a?(String) && mount.start_with?('/') && mount != '/' && File.expand_path(mount) == mount && File.directory?(mount) && File.realpath(mount) == mount
          raise NotImplementedError, 'Safe UF2 directory pinning requires Linux procfs and O_NOFOLLOW' unless File.directory?('/proc/self/fd') && File.const_defined?(:NOFOLLOW)

          destination = File.join(mount, 'FIRMWARE.UF2')
          File.open(mount, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |directory|
            raise ArgumentError, 'mount must be a directory' unless directory.stat.directory?

            # Use the opened directory, never re-resolve the mount path for a
            # write: an unplug/unmount must not redirect data onto the host disk.
            anchor = "/proc/self/fd/#{directory.fileno}"
            validate_target(opts.merge(anchor: anchor))
            current = File.stat(mount)
            raise IOError, 'UF2 mount changed before submission' unless current.dev == directory.stat.dev && current.ino == directory.stat.ino && File.realpath(mount) == mount

            File.open(File.join(anchor, 'FIRMWARE.UF2'), File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
              file.binmode
              written = file.write(bytes)
              raise IOError, 'Incomplete UF2 submission; do not automatically retry' unless written == bytes.bytesize

              file.flush
              file.fsync
            end
          end
          { status: :copied, protocol: :uf2, bytes: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes),
            family_id: opts.fetch(:family_id), board_id: opts.fetch(:board_id), destination: destination,
            flash_verified: false, reboot_verified: false }
        end

        private_class_method def self.validate_target(opts = {})
          board = opts[:board_id]
          raise ArgumentError, 'board_id must be the exact expected INFO_UF2.TXT Board-ID' unless board.is_a?(String) && board.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,255}\z/)

          anchor = opts.fetch(:anchor)
          markers = Dir.children(anchor).select { |name| name.casecmp?('INFO_UF2.TXT') }
          raise ArgumentError, 'Exactly one INFO_UF2.TXT is required on the selected mount' unless markers.length == 1

          marker = File.join(anchor, markers.first)
          raise ArgumentError, 'INFO_UF2.TXT must be a regular nonsymlink file' unless File.lstat(marker).file?

          text = File.open(marker, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
            raise ArgumentError, 'INFO_UF2.TXT must be a bounded regular file' unless file.stat.file? && file.stat.size <= 4096

            file.binmode
            file.read(4097)
          end
          raise ArgumentError, 'Invalid INFO_UF2.TXT bootloader identification' unless text.bytesize <= 4096 && text.match?(/\AUF2 Bootloader[^\r\n]*\r?\n/) && text.match?(/\A[\x09\x0a\x0d\x20-\x7e]*\z/)

          boards = text.lines.filter_map { |line| line.chomp.delete_suffix("\r").match(/\ABoard-ID:[ \t]*(\S+)[ \t]*\z/)&.captures&.first }
          raise ArgumentError, 'INFO_UF2.TXT Board-ID mismatch or ambiguous Board-ID' unless boards == [board]

          family = if board.match?(/\AnRF52840-/i)
                     0xada52840
                   elsif board == 'RPI-RP2'
                     0xe48bff56
                   end
          raise ArgumentError, 'INFO_UF2.TXT Board-ID does not identify the expected MCU family' unless family == opts.fetch(:family_id)
        end

        private_class_method def self.image_bytes(opts = {})
          raw = if opts.key?(:firmware)
                  path = opts[:firmware]
                  raise ArgumentError, 'firmware must name a regular file' unless path.is_a?(String) && File.file?(path)

                  File.open(path, File::RDONLY | File::NONBLOCK) do |file|
                    raise ArgumentError, 'firmware must be a bounded regular file' unless file.stat.file? && file.stat.size <= MAX_IMAGE

                    file.binmode
                    file.read(MAX_IMAGE + 1)
                  end
                else
                  opts[:bytes]
                end
          raise ArgumentError, 'UF2 image must be a binary String of at most 32 MiB' unless raw.is_a?(String) && raw.bytesize <= MAX_IMAGE

          raw.b.freeze
        end

        private_class_method def self.flash_bounds(opts = {})
          raise ArgumentError, 'family_id must be an Integer' unless opts[:family_id].is_a?(Integer)

          case opts[:family_id]
          when 0xada52840
            raise ArgumentError, 'flash_size applies only to RP2040' if opts.key?(:flash_size)

            [0x27000, 0xf4000]
          when 0xe48bff56
            size = opts[:flash_size]
            raise ArgumentError, 'RP2040 requires flash_size in bytes, 4096..16777216 and 4096 aligned' unless size.is_a?(Integer) && (4096..0x1000000).cover?(size) && (size % 4096).zero?

            [0x10000000, 0x10000000 + size]
          else
            raise ArgumentError, 'Unsupported UF2 family_id; only NRF52840 and RP2040 application images are supported'
          end
        end

        private_class_method def self.validate_image(opts = {})
          lower, upper = flash_bounds(opts.merge({}))
          bytes = opts.fetch(:bytes)
          raise ArgumentError, 'UF2 must contain complete nonempty 512-byte blocks' unless bytes.is_a?(String) && bytes.bytesize.positive? && (bytes.bytesize % 512).zero?

          count = bytes.bytesize / 512
          numbers = {}
          regions = []
          count.times do |index|
            block = bytes.byteslice(index * 512, 512)
            magic0, magic1, flags, address, size, number, total, family = block.unpack('V8')
            raise ArgumentError, 'Invalid UF2 magic' unless magic0 == 0x0a324655 && magic1 == 0x9e5d5157 && block.byteslice(508, 4).unpack1('V') == 0x0ab16f30
            raise ArgumentError, 'Only plain main-flash UF2 blocks with family IDs are supported' unless flags == 0x2000
            raise ArgumentError, 'UF2 family mismatch or mixed families' unless family == opts.fetch(:family_id)
            raise ArgumentError, 'Supported UF2 bootloaders require 256-byte payloads and target alignment' unless size == 256 && (address % 256).zero?
            raise ArgumentError, 'Invalid UF2 block count or number' unless total == count && number < count
            raise ArgumentError, 'Duplicate UF2 block number' if numbers[number]
            raise ArgumentError, 'UF2 target address outside application flash' unless address >= lower && address + size <= upper

            numbers[number] = true
            regions << [address, address + size]
          end
          regions.sort.each_cons(2) do |left, right|
            raise ArgumentError, 'Overlapping UF2 target addresses' if left[1] > right[0]
          end
        end

        public_class_method def self.authors
          "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
        end

        public_class_method def self.help
          puts "USAGE:
            # Validate and submit firmware through UF2 mass storage.
            #{self}.install(
              protocol: 'required - explicit :uf2 protocol selection',
              bytes: 'optional - complete original UF2 image bytes instead of firmware',
              firmware: 'optional - regular UF2 image file instead of bytes',
              mount: 'required - absolute bootloader directory explicitly selected by the operator',
              family_id: 'required - expected numeric UF2 MCU family identifier',
              board_id: 'required - exact Board-ID from the selected bootloader INFO_UF2.TXT',
              flash_size: 'optional - required for RP2040 only; installed flash capacity in bytes, 4096 aligned, at most 16 MiB'
            )

            # Return module author information.
            #{self}.authors
          "
        end
      end
    end
  end
end
