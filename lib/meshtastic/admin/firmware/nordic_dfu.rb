# frozen_string_literal: true

require 'json'
require 'zlib'
require 'digest'
require 'timeout'

module Meshtastic
  module Admin
    module Firmware
      # Adafruit SDK11 legacy BLE DFU, not Nordic Secure DFU.
      module NordicDFU
        CONTROL_UUID = '00001531-1212-efde-1523-785feabcd123'
        PACKET_UUID = '00001532-1212-efde-1523-785feabcd123'
        MAX_PACKAGE = 8 * 1024 * 1024

        public_class_method def self.install(opts = {})
          unknown = opts.keys - %i[package package_bytes gatt address adapter timeout protocol]
          raise ArgumentError, "Unsupported Nordic DFU options: #{unknown.join(', ')}" unless unknown.empty?
          raise ArgumentError, 'protocol must be :nordic_dfu' unless opts.fetch(:protocol, :nordic_dfu) == :nordic_dfu
          raise ArgumentError, 'Supply exactly one of package or package_bytes' unless opts.key?(:package) ^ opts.key?(:package_bytes)

          image, init = package(opts.merge({}))
          timeout = opts.fetch(:timeout, 30)
          raise ArgumentError, 'timeout must be finite and positive' unless timeout.is_a?(Numeric) && timeout.positive? && timeout.finite?

          gatt = opts[:gatt]
          unless gatt
            require_relative 'ble'
            gatt = BLE::BlueZ.new(address: opts.fetch(:address), adapter: opts.fetch(:adapter, 'hci0'),
                                  timeout: timeout, service_uuid: '00001530-1212-efde-1523-785feabcd123').connect
          end
          session = { gatt: gatt, timeout: timeout }
          gatt.subscribe(uuid: CONTROL_UUID)
          control(session.merge(bytes: [1, 4].pack('C*')))
          packet(session.merge(bytes: [0, 0, image.bytesize].pack('V3')))
          response(session.merge(opcode: 1))
          control(session.merge(bytes: [2, 0].pack('C*')))
          init.bytes.each_slice(20) { |chunk| packet(session.merge(bytes: chunk.pack('C*'))) }
          control(session.merge(bytes: [2, 1].pack('C*')))
          response(session.merge(opcode: 2))
          # PRN=1 bounds outstanding data and catches loss before any next chunk.
          control(session.merge(bytes: [8, 1].pack('Cv')))
          control(session.merge(bytes: [3].pack('C')))
          offset = 0
          image.bytes.each_slice(20) do |chunk|
            packet(session.merge(bytes: chunk.pack('C*')))
            offset += chunk.length
            if offset == image.bytesize
              response(session.merge(opcode: 3))
            else
              receipt = notification(session)
              raise IOError, 'DFU packet receipt offset mismatch' unless receipt == [17, offset].pack('CV')
            end
          end
          control(session.merge(bytes: [4].pack('C')))
          response(session.merge(opcode: 4))
          control(session.merge(bytes: [5].pack('C')))
          { status: :verified, protocol: :nordic_dfu, bytes: image.bytesize,
            sha256: Digest::SHA256.hexdigest(image), reboot_verified: false }
        ensure
          gatt&.close
        end

        private_class_method def self.control(opts = {})
          opts.fetch(:gatt).write(uuid: CONTROL_UUID, bytes: opts.fetch(:bytes), response: true)
        end

        private_class_method def self.packet(opts = {})
          opts.fetch(:gatt).write(uuid: PACKET_UUID, bytes: opts.fetch(:bytes), response: false)
        end

        private_class_method def self.notification(opts = {})
          event = opts.fetch(:gatt).notification(timeout: opts.fetch(:timeout))
          raise Timeout::Error, 'DFU notification timeout; session cannot safely resume' unless event
          raise IOError, 'Invalid DFU notification envelope' unless event.is_a?(Hash) && event[:uuid].to_s.downcase == CONTROL_UUID && event[:bytes].is_a?(String)

          event[:bytes].b
        end

        private_class_method def self.response(opts = {})
          bytes = notification(opts.merge({}))
          expected = [16, opts.fetch(:opcode), 1].pack('C*')
          raise IOError, "DFU response rejected or out of order: #{bytes.unpack1('H*')}" unless bytes == expected
        end

        private_class_method def self.package(opts = {})
          raw = opts[:package_bytes] || File.binread(opts.fetch(:package), MAX_PACKAGE + 1)
          raise ArgumentError, 'DFU ZIP must be a bounded binary String' unless raw.is_a?(String) && raw.bytesize <= MAX_PACKAGE

          entries = archive(bytes: raw.b)
          root = JSON.parse(entries.fetch('manifest.json'))
          raise ArgumentError, 'Invalid manifest JSON object' unless root.is_a?(Hash)

          manifest = root.fetch('manifest')
          raise ArgumentError, 'Only application-only legacy Adafruit DFU packages are supported' unless manifest.is_a?(Hash) && manifest.compact.keys == ['application']

          app = manifest.fetch('application')
          raise ArgumentError, 'Invalid application manifest entry' unless app.is_a?(Hash)

          image = entries.fetch(app.fetch('bin_file'))
          init = entries.fetch(app.fetch('dat_file'))
          raise ArgumentError, 'DFU image must be nonempty and word aligned' if image.empty? || image.bytesize % 4 != 0
          raise ArgumentError, 'Invalid legacy Adafruit init packet' if init.bytesize < 12 || init.unpack1('v') != 0x52

          count = init.byteslice(8, 2).unpack1('v')
          raise ArgumentError, 'Unsupported init variant: expected legacy CRC16, not Secure DFU or signed extension' unless count.positive? && init.bytesize == 12 + (2 * count)
          raise ArgumentError, 'DFU image CRC16 mismatch' unless crc16(bytes: image) == init.byteslice(-2, 2).unpack1('v')

          [image, init]
        rescue KeyError, JSON::ParserError, TypeError => e
          raise ArgumentError, "Invalid DFU package: #{e.message}"
        end

        private_class_method def self.crc16(opts = {})
          crc = 0xffff
          opts.fetch(:bytes).each_byte do |byte|
            crc = ((crc >> 8) | (crc << 8)) & 0xffff
            crc ^= byte
            crc ^= (crc & 0xff) >> 4
            crc ^= (crc << 12) & 0xffff
            crc ^= ((crc & 0xff) << 5) & 0xffff
          end
          crc
        end

        # Read ZIP entries in memory, never extract paths or invoke a CLI.
        private_class_method def self.archive(opts = {})
          raw = opts.fetch(:bytes)
          eocd = raw.rindex("PK\x05\x06".b)
          raise ArgumentError, 'Invalid ZIP end record' unless eocd && raw.bytesize >= eocd + 22

          disk, cd_disk, disk_count, count, cd_size, cd_offset, comment = raw.byteslice(eocd + 4, 18).unpack('vvvvVVv')
          unless disk.zero? && cd_disk.zero? && count == disk_count && count.between?(1, 32) &&
                 cd_offset + cd_size == eocd && eocd + 22 + comment == raw.bytesize
            raise ArgumentError, 'Unsupported ZIP layout (split, ZIP64, or invalid directory)'
          end

          entries = {}
          cursor = cd_offset
          count.times do
            header = raw.byteslice(cursor, 46)
            raise ArgumentError, 'Invalid ZIP directory entry' unless header&.bytesize == 46 && header.unpack1('V') == 0x02014b50

            fields = header.unpack('VvvvvvvVVVvvvvvVV')
            flags, method, crc, packed, size = fields.values_at(3, 4, 7, 8, 9)
            name_size, extra_size, comment_size, entry_disk, offset = fields.values_at(10, 11, 12, 13, 16)
            name = raw.byteslice(cursor + 46, name_size)
            unless flags.nobits?(~0x800) && [0, 8].include?(method) && entry_disk.zero? && size <= MAX_PACKAGE && packed <= MAX_PACKAGE &&
                   name && name.match?(%r{\A[\w./-]+\z}) && !name.split('/').include?('..') && !name.start_with?('/') && !entries.key?(name)
              raise ArgumentError, 'Unsupported or unsafe ZIP entry'
            end

            local = raw.byteslice(offset, 30)
            raise ArgumentError, 'Invalid ZIP local header' unless local&.bytesize == 30 && local.unpack1('V') == 0x04034b50

            lfields = local.unpack('VvvvvvVVVvv')
            lname_size, lextra_size = lfields.values_at(9, 10)
            start = offset + 30 + lname_size + lextra_size
            unless lfields.values_at(2, 3, 6, 7, 8) == [flags, method, crc, packed, size] &&
                   raw.byteslice(offset + 30, lname_size) == name && start + packed <= cd_offset
              raise ArgumentError, 'Inconsistent ZIP local entry'
            end

            bytes = raw.byteslice(start, packed)
            bytes = inflate(bytes: bytes, size: size) if method == 8
            raise ArgumentError, 'ZIP entry size or CRC32 mismatch' unless bytes && bytes.bytesize == size && Zlib.crc32(bytes) == crc

            entries[name] = bytes
            cursor += 46 + name_size + extra_size + comment_size
          end
          raise ArgumentError, 'Invalid ZIP directory length' unless cursor == eocd

          entries
        end

        private_class_method def self.inflate(opts = {})
          inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
          output = ''.b
          inflater.inflate(opts.fetch(:bytes)) do |chunk|
            raise ArgumentError, 'ZIP decompression exceeds declared size' if output.bytesize + chunk.bytesize > opts.fetch(:size)

            output << chunk
          end
          raise ArgumentError, 'Invalid ZIP deflate stream' unless inflater.finished? && inflater.total_in == opts.fetch(:bytes).bytesize

          output
        rescue Zlib::Error => e
          raise ArgumentError, "Invalid ZIP deflate stream: #{e.message}"
        ensure
          inflater&.close
        end

        public_class_method def self.authors
          ['Meshtastic Ruby contributors']
        end

        public_class_method def self.help
          puts <<~HELP
            Install application via Adafruit legacy BLE DFU.
            #{self}.install(
              protocol: 'optional - protocol selector, must be nordic_dfu',
              package: 'optional - DFU ZIP filename; required unless package_bytes is supplied',
              package_bytes: 'optional - raw DFU ZIP bytes instead of filename',
              gatt: 'optional - connected adapter implementing write/subscribe/notification/close',
              address: 'optional - bootloader BLE address; required without gatt',
              adapter: 'optional - BlueZ adapter name, default hci0',
              timeout: 'optional - positive notification timeout seconds, default 30'
            )

            List module contributing authors.
            #{self}.authors
          HELP
        end
      end
    end
  end
end
