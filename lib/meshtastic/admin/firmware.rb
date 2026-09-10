# frozen_string_literal: true

require 'digest'
require 'meshtastic/xmodem_pb'

module Meshtastic
  module Admin
    module Firmware
      SOH_SIZE = 128
      PAD = 0x1A

      public_class_method def self.sha256(opts = {})
        Digest::SHA256.digest(firmware_bytes(opts.merge({})))
      end

      public_class_method def self.request_ota(opts = {})
        hash = opts[:ota_hash] || sha256(opts)
        raise ArgumentError, 'ota_hash must be 32 bytes' unless hash.to_s.bytesize == 32

        event = Meshtastic::AdminMessage::OTAEvent.new(
          reboot_ota_mode: opts[:mode] || :OTA_BLE,
          ota_hash: hash.to_s.b
        )
        Admin.send(opts.merge(ota_request: event))
      end

      public_class_method def self.enter_dfu(opts = {})
        Admin.send(opts.merge(enter_dfu_mode_request: true))
      end

      public_class_method def self.reboot_ota(opts = {})
        Admin.send(opts.merge(reboot_ota_seconds: opts[:seconds] || 10))
      end

      public_class_method def self.xmodem_blocks(opts = {})
        payload = opts[:bytes].to_s.b
        block_size = opts[:block_size] || SOH_SIZE
        raise ArgumentError, 'firmware bytes are empty' if payload.empty?

        blocks = []
        seq = 1
        offset = 0
        while offset < payload.bytesize
          chunk = payload.byteslice(offset, block_size).to_s.b
          chunk = chunk.ljust(block_size, PAD.chr) if chunk.bytesize < block_size
          blocks << Meshtastic::XModem.new(
            control: block_size > SOH_SIZE ? :STX : :SOH,
            seq: seq,
            crc16: crc16(data: chunk),
            buffer: chunk
          )
          seq += 1
          offset += block_size
        end
        blocks << Meshtastic::XModem.new(control: :EOT, seq: seq)
        blocks
      end

      public_class_method def self.send_xmodem(opts = {})
        packet = opts[:xmodem]
        to_radio = Meshtastic::ToRadio.new
        to_radio.xmodemPacket = packet
        send_phone(opts.merge(to_radio: to_radio))
      end

      public_class_method def self.install(opts = {})
        bytes = firmware_bytes(opts.merge({}))
        request_ota(opts.merge(bytes: bytes))
        return if opts[:mqtt_obj]

        xmodem_blocks(bytes: bytes).each do |packet|
          send_xmodem(opts.merge(xmodem: packet))
        end
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

          # Send the legacy reboot_ota_seconds admin field.
          #{self}.reboot_ota(
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            seconds: 'optional - delay before OTA reboot in seconds (default: 10)'
          )

          # Split firmware bytes into XModem SOH blocks plus EOT.
          #{self}.xmodem_blocks(
            bytes: 'required - raw firmware image bytes to chunk',
            block_size: 'optional - XModem block size in bytes (default: 128)'
          )

          # Write one XModem protobuf as a PhoneAPI ToRadio frame.
          #{self}.send_xmodem(
            xmodem: 'required - Meshtastic::XModem protobuf to write',
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            tcp_obj: 'optional - TCP handle from Meshtastic::TCP.connect',
            bluetooth_obj: 'optional - BLE handle from Meshtastic::Bluetooth.connect'
          )

          # Hash, send ota_request, then stream XModem on serial/TCP/BLE.
          #{self}.install(
            firmware: 'optional - path to a firmware .bin on disk',
            bytes: 'optional - raw firmware image bytes if no path is given',
            serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
            tcp_obj: 'optional - TCP handle from Meshtastic::TCP.connect',
            bluetooth_obj: 'optional - BLE handle from Meshtastic::Bluetooth.connect',
            mqtt_obj: 'optional - MQTT client; publishes ota_request only',
            mode: 'optional - :OTA_BLE or :OTA_WIFI (default: :OTA_BLE)'
          )

          # Print the AUTHOR(S) string for this module.
          #{self}.authors
        "
      end

      private_class_method def self.firmware_bytes(opts = {})
        if opts[:bytes]
          opts[:bytes].to_s.b
        elsif opts[:firmware]
          File.binread(opts[:firmware])
        else
          raise ArgumentError, 'firmware path or bytes is required'
        end
      end

      private_class_method def self.crc16(opts = {})
        crc = 0
        opts[:data].to_s.b.each_byte do |byte|
          crc ^= byte << 8
          8.times do
            crc = crc[15] == 1 ? ((crc << 1) ^ 0x1021) : (crc << 1)
            crc &= 0xffff
          end
        end
        crc
      end

      private_class_method def self.send_phone(opts = {})
        if opts[:serial_obj]
          Serial.send_to_radio(opts)
        elsif opts[:tcp_obj]
          TCP.send_to_radio(opts)
        elsif opts[:bluetooth_obj]
          Bluetooth.send_to_radio(opts)
        else
          raise ArgumentError, 'serial_obj, bluetooth_obj, or tcp_obj is required for XModem'
        end
      end
    end
  end
end
