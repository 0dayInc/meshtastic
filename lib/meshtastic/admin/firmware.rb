# frozen_string_literal: true

require 'digest'
require 'socket'
require 'timeout'


module Meshtastic
  module Admin
    module Firmware
      public_class_method def self.sha256(opts = {})
        Digest::SHA256.digest(firmware_bytes(opts.merge({})))
      end

      public_class_method def self.request_ota(opts = {})
        mode = opts.fetch(:mode, :OTA_BLE)
        raise ArgumentError, 'mode must be :OTA_BLE or :OTA_WIFI' unless %i[OTA_BLE OTA_WIFI].include?(mode)

        hash = opts[:ota_hash] || sha256(opts)
        raise ArgumentError, 'ota_hash must be a raw 32-byte String' unless hash.is_a?(String) && hash.bytesize == 32
        raise ArgumentError, 'ota_hash does not match firmware bytes' if opts[:ota_hash] && (opts.key?(:bytes) || opts.key?(:firmware)) && hash != sha256(opts)

        event = Meshtastic::AdminMessage::OTAEvent.new(
          reboot_ota_mode: mode,
          ota_hash: hash.b
        )
        Admin.send(opts.except(:bytes, :firmware, :ota_hash, :mode).merge(ota_request: event))
      end

      public_class_method def self.enter_dfu(opts = {})
        Admin.send(opts.merge(enter_dfu_mode_request: true))
      end

      public_class_method def self.reboot_ota(opts = {})
        opts.merge({})
        raise NotImplementedError, 'reboot_ota_seconds is not handled by current firmware; use request_ota'
      end

      public_class_method def self.xmodem_blocks(opts = {})
        opts.merge({})
        raise NotImplementedError, 'PhoneAPI XModem transfers filesystem files, not firmware images'
      end

      public_class_method def self.send_xmodem(opts = {})
        opts.merge({})
        raise NotImplementedError, 'PhoneAPI XModem transfers filesystem files, not firmware images'
      end

      public_class_method def self.install(opts = {})
        validate_verification(opts[:verify]) if opts.key?(:verify)
        options = opts.except(:verify)
        result = case opts[:protocol]
                 when :unified_ble then BLE.install(options)
                 when :esp_rom then SerialBootloader.install(options)
                 when :nordic_dfu then NordicDFU.install(options)
                 when :unified_wifi then install_wifi(options)
                 else raise NotImplementedError, 'install requires explicit protocol: :unified_wifi, :unified_ble, :esp_rom or :nordic_dfu'
                 end
        return result unless opts[:verify]

        result.merge(verify_reboot(opts[:verify])).merge(loader_status: result[:status], reboot_verified: true, boot_verified: true)
      end

      private_class_method def self.install_wifi(opts = {})
        validate_install(opts.merge({}))
        bytes = firmware_bytes(opts.merge({}))
        digest = Digest::SHA256.hexdigest(bytes)
        timeout = opts.fetch(:timeout, 120)
        socket = connect_loader(opts.merge(timeout: timeout))
        Timeout.timeout(timeout) do
          socket.write("VERSION\n")
          version = response(socket: socket)
          raise IOError, "Invalid loader VERSION: #{version}" unless version.match?(/\AOK \d+ \S+ \d+ \S+\z/)

          socket.write("OTA #{bytes.bytesize} #{digest}\n")
          line = response(socket: socket)
          line = response(socket: socket) if line == 'ERASING'
          raise IOError, "OTA handshake rejected: #{line}" unless line == 'OK'

          upload(socket: socket, bytes: bytes)
          { status: :verified, bytes: bytes.bytesize, sha256: digest, loader_version: version.delete_prefix('OK ') }
        end
      ensure
        socket&.close
      end

      public_class_method def self.verify_reboot(opts = {})
        validate_verification(opts.merge({}))
        handle = nil
        transport = { tcp: Meshtastic::TCP, bluetooth: Meshtastic::Bluetooth, serial: Meshtastic::Serial }.fetch(opts.fetch(:transport))
        key = { tcp: :tcp_obj, bluetooth: :bluetooth_obj, serial: :serial_obj }.fetch(opts.fetch(:transport))
        Timeout.timeout(opts.fetch(:timeout, 60)) do
          sleep opts.fetch(:reboot_delay, 3)
          begin
            handle = if opts[:reconnect]
                       opts[:reconnect].call(transport: opts.fetch(:transport), connection: opts.fetch(:connection, {}), timeout: opts.fetch(:timeout, 60))
                     else
                       transport.connect(opts.fetch(:connection).merge(want_config: true))
                     end
            transport.wait_for_config(key => handle, timeout: opts.fetch(:timeout, 60))
          rescue IOError, SystemCallError
            transport.disconnect(key => handle) if handle
            handle = nil
            sleep 0.25
            retry
          end
          reply = Admin.request(key => handle, get_device_metadata_request: true, timeout: opts.fetch(:timeout, 60))
          metadata = reply.fetch(:value).to_h
          raise IOError, "Firmware version mismatch: #{metadata[:firmware_version].inspect}" unless metadata[:firmware_version] == opts.fetch(:expected_version)
          raise IOError, 'Post-reboot node identity mismatch' if opts[:expected_node] && handle[:my_node_num] != opts[:expected_node]

          { status: :boot_verified, firmware_version: metadata[:firmware_version], node_num: handle[:my_node_num], metadata: metadata }
        end
      ensure
        transport.disconnect(key => handle) if handle
      end

      private_class_method def self.validate_verification(opts = {})
        raise ArgumentError, 'verify must be a Hash of verify_reboot options' unless opts.is_a?(Hash)

        allowed = %i[transport connection expected_version expected_node reconnect timeout reboot_delay]
        raise ArgumentError, 'Unknown reboot verification option' unless (opts.keys - allowed).empty?
        raise ArgumentError, 'transport must be :tcp, :bluetooth or :serial' unless %i[tcp bluetooth serial].include?(opts[:transport])
        raise ArgumentError, 'expected_version must be a nonempty firmware version String' unless opts[:expected_version].is_a?(String) && !opts[:expected_version].empty?
        raise ArgumentError, 'expected_node must be a numeric node ID' if opts.key?(:expected_node) && !(opts[:expected_node].is_a?(Integer) && (1..0xffffffff).cover?(opts[:expected_node]))

        timeout = opts.fetch(:timeout, 60)
        delay = opts.fetch(:reboot_delay, 3)
        raise ArgumentError, 'timeout must be positive finite seconds' unless timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && timeout.positive?
        raise ArgumentError, 'reboot_delay must be nonnegative finite seconds' unless delay.is_a?(Numeric) && delay.real? && delay.finite? && delay >= 0
        raise ArgumentError, 'reconnect must be callable' if opts.key?(:reconnect) && !opts[:reconnect].respond_to?(:call)
        return if opts[:reconnect]

        connection = opts[:connection]
        required = { tcp: :host, bluetooth: :address, serial: :block_dev }.fetch(opts[:transport])
        raise ArgumentError, "connection must specify #{required}" unless connection.is_a?(Hash) && connection[required].is_a?(String) && !connection[required].strip.empty?

        keys = { tcp: %i[host port], bluetooth: %i[address adapter timeout], serial: %i[block_dev baud] }.fetch(opts[:transport])
        raise ArgumentError, 'Only fresh connection endpoint options are allowed' unless (connection.keys - keys).empty?

        if opts[:transport] == :tcp
          port = connection.fetch(:port, 4403)
          raise ArgumentError, 'Application TCP port must be in 1..65535' unless port.is_a?(Integer) && (1..65_535).cover?(port)
        elsif opts[:transport] == :bluetooth
          # Construction validates address/adapter/timeout without touching D-Bus.
          Meshtastic::Bluetooth::BlueZ.new(address: connection[:address], adapter: connection.fetch(:adapter, 'hci0'), timeout: connection.fetch(:timeout, 15))
        end
      end

      private_class_method def self.upload(opts = {})
        socket = opts.fetch(:socket)
        writer = Thread.new do
          Thread.current.report_on_exception = false
          socket.write(opts.fetch(:bytes))
        rescue IOError, SystemCallError
          socket.close
          raise
        end
        loop do
          line = response(socket: socket)
          break if line == 'OK'
          raise IOError, "OTA transfer rejected: #{line}" unless line == 'ACK'
        end
        writer.value
      ensure
        writer&.kill
        writer&.join
      end

      private_class_method def self.connect_loader(opts = {})
        attempts = 0
        begin
          attempts += 1
          Socket.tcp(opts.fetch(:host), opts.fetch(:port, 3232), connect_timeout: opts.fetch(:timeout))
        rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT
          raise if attempts > opts.fetch(:retries, 3)

          sleep opts.fetch(:retry_delay, 1)
          retry
        end
      end

      private_class_method def self.response(opts = {})
        line = opts.fetch(:socket).gets("\n", 513)
        raise IOError, 'OTA connection closed before confirmation' unless line
        raise IOError, 'Invalid OTA response framing' unless line.end_with?("\n") && line.bytesize <= 512

        line.chomp
      end

      private_class_method def self.validate_install(opts = {})
        allowed = %i[protocol host port bytes firmware timeout retries retry_delay]
        unknown = opts.keys - allowed
        raise ArgumentError, "Unsupported install options: #{unknown.join(', ')}" unless unknown.empty?
        raise ArgumentError, 'host must be a nonempty string' unless opts[:host].is_a?(String) && !opts[:host].strip.empty?

        port = opts.fetch(:port, 3232)
        retries = opts.fetch(:retries, 3)
        timeout = opts.fetch(:timeout, 120)
        delay = opts.fetch(:retry_delay, 1)
        raise ArgumentError, 'port must be in 1..65535' unless port.is_a?(Integer) && (1..65_535).cover?(port)
        raise ArgumentError, 'retries must be in 0..20' unless retries.is_a?(Integer) && (0..20).cover?(retries)
        raise ArgumentError, 'timeout must be finite and positive' unless timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?
        raise ArgumentError, 'retry_delay must be finite and nonnegative' unless delay.is_a?(Numeric) && delay.finite? && delay >= 0
      end

      public_class_method def self.authors
        "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
      end

      public_class_method def self.help
        puts "USAGE:
          # SHA-256 the firmware image bytes or file.
          #{self}.sha256(
            firmware: 'optional - path to a firmware .bin on disk',
            bytes: 'optional - raw firmware image bytes if no path is given'
          )

          # Send Admin ota_request with the image hash and OTA mode.
          #{self}.request_ota(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            mqtt_obj: 'optional - MQTT client from Meshtastic::MQTT.connect',
            firmware: 'optional - path to a firmware .bin on disk',
            ota_hash: 'optional - 32-byte SHA-256 digest if not hashing firmware',
            mode: 'optional - :OTA_BLE or :OTA_WIFI (default: :OTA_BLE)'
          )

          # Ask the node to enter DFU / UF2 bootloader mode.
          #{self}.enter_dfu(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
          )

          # Reject the obsolete unhandled legacy OTA reboot field.
          #{self}.reboot_ota

          # Reject filesystem XModem as a firmware update mechanism.
          #{self}.xmodem_blocks

          # Reject filesystem XModem as a firmware update mechanism.
          #{self}.send_xmodem

          # Upload using an explicitly selected native loader protocol.
          #{self}.install(
            protocol: 'required - :unified_wifi, :unified_ble, :esp_rom or :nordic_dfu; no protocol guessing',
            verify: 'optional - verify_reboot options Hash; success becomes :boot_verified only after a fresh reply',
            host: 'required - OTA loader IP address or hostname, not a mesh node ID',
            port: 'optional - separate OTA TCP service port (default: 3232)',
            firmware: 'optional - matching application .bin path, exclusive with bytes',
            bytes: 'optional - nonempty raw image String, exclusive with firmware',
            timeout: 'optional - positive seconds per connect and whole transfer (default: 120)',
            retries: 'optional - connection refusal/timeout retries, 0..20 (default: 3)',
            retry_delay: 'optional - nonnegative seconds between connection retries (default: 1)'
          )
          # First use request_ota with the matching mode to pin the same image hash.
          # install never sends preparation commands; :verified means loader OK, not boot confirmation.
          # BLE.help, NordicDFU.help and SerialBootloader.help document protocol-specific options.

          # Reconnect and request fresh correlated application firmware metadata.
          #{self}.verify_reboot(
            transport: 'required - :tcp, :bluetooth or :serial for the restarted application',
            connection: 'optional - connect options Hash with explicit host/address/block_dev; required without reconnect',
            expected_version: 'required - exact firmware version reported by the intended application',
            expected_node: 'optional - numeric node identity to verify after restart',
            reconnect: 'optional - callable accepting options Hash and returning a newly connected transport handle',
            timeout: 'optional - entire reboot/reconnect/config/metadata deadline seconds, default 60',
            reboot_delay: 'optional - initial wait for loader restart, default 3 seconds'
          )

          # Print the AUTHOR(S) string for this module.
          #{self}.authors
        "
      end

      private_class_method def self.firmware_bytes(opts = {})
        raise ArgumentError, 'provide exactly one of firmware or bytes' unless opts.key?(:bytes) ^ opts.key?(:firmware)

        bytes = opts.key?(:bytes) ? opts[:bytes] : File.binread(opts[:firmware])
        raise ArgumentError, 'firmware bytes must be a nonempty String' unless bytes.is_a?(String) && !bytes.empty?

        bytes.b
      end
    end
  end
end

require 'meshtastic/admin/firmware/ble'
require 'meshtastic/admin/firmware/serial_bootloader'
require 'meshtastic/admin/firmware/nordic_dfu'
