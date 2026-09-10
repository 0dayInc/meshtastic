# frozen_string_literal: true

require 'dbus'
require 'timeout'

module Meshtastic
  module Bluetooth
    # Linux BlueZ transport for raw Meshtastic protobuf messages.
    class BlueZ # rubocop:disable Metrics/ClassLength
      # https://github.com/meshtastic/python/blob/master/meshtastic/ble_interface.py
      SERVICE_UUID = '6ba1b218-15a8-461f-9fa8-5dcae273eafd'
      TORADIO_UUID = 'f75c76d2-129e-4dad-a1dd-7866124401e7'
      FROMRADIO_UUID = '2c55e69e-4993-11ed-b878-0242ac120002'

      def self.scan(adapter: 'hci0', timeout: 5)
        new(address: '00:00:00:00:00:00', adapter: adapter, timeout: timeout).scan_adapter
      end

      def connect
        @mutex.synchronize { connect_locked }
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
        raise IOError, "Bluetooth device #{@address} not found on #{@adapter}; scan first" unless @device_path
        raise IOError, "Bluetooth device is not Paired. Run: bluetoothctl pair #{@address} (enter the PIN shown by your radio), then retry." unless properties(@device_path, 'org.bluez.Device1')['Paired']

        @disconnect_needed = true
        call(@device_path, 'org.bluez.Device1', 'Connect')
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        until properties(@device_path, 'org.bluez.Device1')['ServicesResolved']
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise IOError, 'Bluetooth ServicesResolved timed out' unless remaining.positive?

          sleep [0.1, remaining].min
        end
        @to_radio = characteristic(TORADIO_UUID)
        @from_radio = characteristic(FROMRADIO_UUID)
        self
      rescue StandardError
        close_locked
        raise
      end

      def close
        @mutex.synchronize { close_locked }
      end

      def close_locked
        call(@device_path, 'org.bluez.Device1', 'Disconnect') if @bus && @disconnect_needed
      ensure
        @disconnect_needed = false
        release_bus
      end

      def scan_adapter
        started = false
        @mutex.synchronize do
          @bus = DBus::ASystemBus.allocate
          bounded { @bus.__send__(:initialize) }
          objects = managed_objects
          check_adapter(objects)
          adapter_path = "/org/bluez/#{@adapter}"
          begin
            call(adapter_path, 'org.bluez.Adapter1', 'StartDiscovery')
            started = true
          rescue DBus::Error
            nil
          end
          sleep @timeout
          managed_objects.filter_map do |_path, interfaces|
            device = interfaces['org.bluez.Device1']
            next unless device && device['Adapter'] == adapter_path
            next unless Array(device['UUIDs']).any? { |uuid| uuid.to_s.casecmp?(SERVICE_UUID) }

            { address: device['Address'], name: device['Name'], paired: device['Paired'] }
          end
        ensure
          if @bus && started
            begin
              call("/org/bluez/#{@adapter}", 'org.bluez.Adapter1', 'StopDiscovery')
            rescue DBus::Error
              nil
            end
          end
          release_bus
        end
      end

      def connected!
        raise IOError, 'Bluetooth device disconnected' unless @bus && @from_radio && properties(@device_path, 'org.bluez.Device1')['Connected']
      end

      def read
        @mutex.synchronize do
          connected!
          call(@from_radio, 'org.bluez.GattCharacteristic1', 'ReadValue', ['a{sv}', {}]).first.pack('C*')
        end
      end

      def write(bytes)
        @mutex.synchronize do
          connected!
          # BlueZ request uses Write Request <= MTU-3, Prepare/Execute Write above it.
          # Never fragment protobufs ourselves: each WriteValue is one message.
          call(@to_radio, 'org.bluez.GattCharacteristic1', 'WriteValue', ['ay', bytes.bytes], ['a{sv}', { 'type' => %w[s request] }])
          bytes.bytesize
        end
      end

      def characteristic(uuid)
        objects = managed_objects
        service = objects.find do |_path, interfaces|
          properties = interfaces['org.bluez.GattService1']
          properties && properties['Device'] == @device_path && properties['UUID']&.casecmp?(SERVICE_UUID)
        end&.first
        raise IOError, 'Meshtastic GATT service not found on selected device' unless service

        match = objects.find do |_path, interfaces|
          properties = interfaces['org.bluez.GattCharacteristic1']
          properties && properties['Service'] == service && properties['UUID']&.casecmp?(uuid)
        end&.first
        raise IOError, "Meshtastic GATT characteristic #{uuid} not found" unless match

        match
      end

      def check_adapter(objects)
        adapter = objects.dig("/org/bluez/#{@adapter}", 'org.bluez.Adapter1')
        raise IOError, "Bluetooth adapter #{@adapter} not found" unless adapter
        raise IOError, "Bluetooth adapter #{@adapter} is not powered" unless adapter['Powered']
      end

      def release_bus
        socket = @bus&.message_queue&.socket
        socket.close if socket && !socket.closed?
        @bus = nil
      end

      def properties(path, interface)
        call(path, 'org.freedesktop.DBus.Properties', 'GetAll', ['s', interface]).first
      end

      def managed_objects
        call('/', 'org.freedesktop.DBus.ObjectManager', 'GetManagedObjects').first
      end

      def call(path, interface, member, *parameters)
        message = DBus::Message.new(DBus::Message::METHOD_CALL)
        message.destination = 'org.bluez'
        message.path = path
        message.interface = interface
        message.member = member
        parameters.each { |type, value| message.add_param(type, value) }
        bounded { @bus.send_sync_or_async(message) }
      end

      # ruby-dbus 0.25 has no method timeout API. An interrupted bus must never
      # be reused because its pending reply bookkeeping may be inconsistent.
      def bounded(&)
        Timeout.timeout(@timeout, &)
      rescue Timeout::Error
        release_bus
        raise IOError, 'Bluetooth D-Bus operation timed out'
      end

      def initialize(address:, adapter: 'hci0', timeout: 15)
        raise ArgumentError, 'Invalid Bluetooth address' unless address.is_a?(String) && /\A(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\z/.match?(address)

        raise ArgumentError, 'Invalid Bluetooth adapter (expected hciN)' unless adapter.is_a?(String) && /\Ahci\d+\z/.match?(adapter)
        raise ArgumentError, 'Invalid Bluetooth timeout (expected positive finite seconds)' unless timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && timeout.positive?

        @address = address
        @adapter = adapter
        @timeout = timeout
        @mutex = Mutex.new
      end
    end
  end
end
