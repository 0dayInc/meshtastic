# frozen_string_literal: true

module Meshtastic
  module Admin
    module Firmware
      # ESP32 unified loader only; not the legacy firmware-ota protocol.
      module BLE
        SERVICE_UUID = '4fafc201-1fb5-459e-8fcc-c5c9c331914b'
        OTA_UUID = '62ec0272-3ec5-11eb-b378-0242ac130005'
        TX_UUID = '62ec0272-3ec5-11eb-b378-0242ac130003'

        public_class_method def self.install(opts = {})
          unknown = opts.keys - %i[protocol bytes firmware backend address adapter timeout]
          raise ArgumentError, "Unsupported BLE options: #{unknown.join(', ')}" unless unknown.empty?
          raise ArgumentError, 'protocol must be :unified_ble' unless opts.fetch(:protocol, :unified_ble) == :unified_ble

          timeout = opts.fetch(:timeout, 120)
          raise ArgumentError, 'timeout must be positive finite seconds' unless timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && timeout.positive?

          bytes = Firmware.__send__(:firmware_bytes, opts)
          backend = opts[:backend] || BlueZ.new(address: opts[:address], adapter: opts.fetch(:adapter, 'hci0'), timeout: timeout, service_uuid: SERVICE_UUID).connect
          Timeout.timeout(timeout) do
            backend.subscribe(uuid: TX_UUID)
            stream = Stream.new(backend)
            stream.command("VERSION\n")
            version = stream.line
            raise IOError, "Invalid loader VERSION: #{version}" unless version.match?(/\AOK \d+ \S+ \d+ \S+\z/)

            digest = Digest::SHA256.hexdigest(bytes)
            stream.command("OTA #{bytes.bytesize} #{digest}\n")
            reply = stream.line
            reply = stream.line if reply == 'ERASING'
            raise IOError, "OTA handshake rejected: #{reply}" unless reply == 'OK'

            offset = 0
            while offset < bytes.bytesize
              chunk = bytes.byteslice(offset, 20)
              backend.write(uuid: OTA_UUID, bytes: chunk, response: true)
              offset += chunk.bytesize
              reply = stream.line
              expected = offset == bytes.bytesize ? 'OK' : 'ACK'
              raise IOError, "OTA transfer expected #{expected}, received: #{reply}" unless reply == expected
            end
            { status: :verified, bytes: bytes.bytesize, sha256: digest, loader_version: version.delete_prefix('OK ') }
          end
        ensure
          backend&.close
        end

        # Shared backend for unified OTA and Nordic DFU. All bus I/O stays on
        # the caller thread: synchronous replies also dispatch queued signals.
        # No discovery, pairing, address inference, or cross-device UUID lookup.
        class BlueZ < Meshtastic::Bluetooth::BlueZ
          def initialize(address:, service_uuid:, adapter: 'hci0', timeout: 15)
            super(address: address, adapter: adapter, timeout: timeout)
            raise ArgumentError, 'Invalid GATT service UUID' unless service_uuid.is_a?(String) && /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i.match?(service_uuid)

            @service_uuid = service_uuid
            @notifications = []
          end

          def connect_locked
            @bus = DBus::ASystemBus.allocate
            bounded { @bus.__send__(:initialize) }
            objects = managed_objects
            check_adapter(objects)
            @device_path = objects.find do |_path, interfaces|
              device = interfaces['org.bluez.Device1']
              device && device['Address']&.casecmp?(@address) && device['Adapter'] == "/org/bluez/#{@adapter}"
            end&.first
            raise IOError, 'Selected bootloader address not known to BlueZ; discover it explicitly first' unless @device_path

            @disconnect_needed = true
            call(@device_path, 'org.bluez.Device1', 'Connect')
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
            until properties(@device_path, 'org.bluez.Device1')['ServicesResolved']
              raise IOError, 'Bootloader ServicesResolved timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

              sleep 0.05
            end
            self
          rescue StandardError
            close_locked
            raise
          end

          def characteristic(uuid)
            objects = managed_objects
            services = objects.filter_map do |path, interfaces|
              props = interfaces['org.bluez.GattService1']
              path if props && props['Device'] == @device_path && props['UUID']&.casecmp?(@service_uuid)
            end
            matches = objects.filter_map do |path, interfaces|
              props = interfaces['org.bluez.GattCharacteristic1']
              path if props && services.include?(props['Service']) && props['UUID']&.casecmp?(uuid)
            end
            raise IOError, "Expected exactly one GATT characteristic #{uuid} on selected device" unless matches.size == 1

            matches.first
          end

          def connected!
            raise IOError, 'Bootloader disconnected' unless @bus && properties(@device_path, 'org.bluez.Device1')['Connected']
          end

          def write(uuid:, bytes:, response: true)
            @mutex.synchronize do
              connected!
              path = characteristic(uuid)
              call(path, 'org.bluez.GattCharacteristic1', 'WriteValue', ['ay', bytes.bytes], ['a{sv}', { 'type' => ['s', response ? 'request' : 'command'] }])
              bytes.bytesize
            end
          end

          def subscribe(uuid:)
            @mutex.synchronize do
              connected!
              path = characteristic(uuid)
              rule = "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='#{path}'"
              bounded do
                @bus.add_match(rule) do |message|
                  interface, changed = message.params
                  next unless message.path == path && interface == 'org.bluez.GattCharacteristic1' && changed.key?('Value')

                  @notifications << { uuid: uuid, bytes: changed.fetch('Value').pack('C*') }
                end
              end
              call(path, 'org.bluez.GattCharacteristic1', 'StartNotify')
            end
          end

          def notification(timeout:)
            @mutex.synchronize do
              Timeout.timeout(timeout) do
                loop do
                  return @notifications.shift unless @notifications.empty?

                  raise IOError, 'Bootloader bus closed' unless @bus

                  message = @bus.message_queue.pop
                  @bus.process(message)
                end
              end
            end
          rescue Timeout::Error
            release_bus
            raise IOError, 'Bootloader notification timed out; transfer not retried'
          end
        end

        class Stream
          def initialize(backend)
            @backend = backend
            @buffer = +''.b
          end

          def command(bytes)
            offset = 0
            while offset < bytes.bytesize
              @backend.write(uuid: OTA_UUID, bytes: bytes.byteslice(offset, 20), response: true)
              offset += 20
            end
          end

          def line
            loop do
              if (index = @buffer.index("\n"))
                raise IOError, 'Oversized OTA response' if index > 511

                return @buffer.slice!(0, index + 1).chomp
              end
              raise IOError, 'Oversized OTA response' if @buffer.bytesize > 512

              event = @backend.notification(timeout: 120)
              raise IOError, 'OTA disconnected before confirmation' unless event
              raise IOError, 'Unexpected OTA notification UUID' unless event[:uuid].to_s.casecmp?(TX_UUID)

              raise IOError, 'Invalid OTA notification bytes' unless event[:bytes].is_a?(String) && !event[:bytes].empty?

              @buffer << event.fetch(:bytes)
            end
          end
        end

        public_class_method def self.authors
          Firmware.authors
        end

        public_class_method def self.help
          puts "USAGE:
            # Upload using the unified ESP32 BLE protocol.
            #{self}.install(
              backend: 'optional - connected GATT backend; default selected-device BlueZ',
              address: 'optional - required bootloader BLE MAC address when backend is omitted',
              adapter: 'optional - selected BlueZ adapter, default hci0',
              bytes: 'optional - application image bytes, exclusive with firmware',
              firmware: 'optional - application image path, exclusive with bytes',
              timeout: 'optional - whole transfer deadline seconds, default 120'
            )
            # Print the authors of this module.
            #{self}.authors
          "
        end
      end
    end
  end
end
