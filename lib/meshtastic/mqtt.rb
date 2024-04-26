# frozen_string_literal: true

require 'base64'
require 'geocoder'
require 'json'
require 'mqtt'
require 'openssl'
require 'securerandom'

# Avoiding Namespace Collisions
MQTTClient = MQTT::Client

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  module MQTT
    # Supported Method Parameters::
    # mqtt_obj = Meshtastic::MQQT.connect(
    #   host: 'optional - mqtt host (default: mqtt.meshtastic.org)',
    #   port: 'optional - mqtt port (defaults: 1883)',
    #   username: 'optional - mqtt username (default: meshdev)',
    #   password: 'optional - (default: large4cats)'
    # )

    public_class_method def self.connect(opts = {})
      # Publicly available MQTT server / credentials by default
      host = opts[:host] ||= 'mqtt.meshtastic.org'
      port = opts[:port] ||= 1883
      username = opts[:username] ||= 'meshdev'
      password = opts[:password] ||= 'large4cats'

      mqtt_obj = MQTTClient.connect(
        host: host,
        port: port,
        username: username,
        password: password
      )

      mqtt_obj.client_id = SecureRandom.random_bytes(8).unpack1('H*')

      mqtt_obj
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # Meshtastic::MQQT.subscribe(
    #   mqtt_obj: 'required - mqtt_obj returned from #connect method'
    #   region: 'optional - region (default: US)',
    #   channel: 'optional - channel name (default: LongFast)',
    #   psk: 'optional - channel pre-shared key (default: AQ==)',
    #   qos: 'optional - quality of service (default: 0)',
    #   json: 'optional - JSON output (default: false)'
    # )

    public_class_method def self.subscribe(opts = {})
      mqtt_obj = opts[:mqtt_obj]
      region = opts[:region] ||= 'US'
      channel = opts[:channel] ||= 'LongFast'
      psk = opts[:psk] ||= 'AQ=='
      qos = opts[:qos] ||= 0
      json = opts[:json] ||= false

      # TODO: Find JSON URI for this
      root_topic = "msh/#{region}/2/json" if json
      # root_topic = "msh/#{region}/2/e" unless json
      root_topic = "msh/#{region}/2/c" unless json
      mqtt_obj.subscribe("#{root_topic}/#{channel}/#", qos)

      # Decrypt the message
      # Our AES key is 128 or 256 bits, shared as part of the 'Channel' specification.

      # Actual pre-shared key for LongFast channel
      psk = '1PG7OiApB1nwvP+rz05pAQ==' if channel == 'LongFast'
      padded_psk = psk.ljust(psk.length + ((4 - (psk.length % 4)) % 4), '=')
      replaced_psk = padded_psk.gsub('-', '+').gsub('_', '/')
      psk = replaced_psk
      dec_psk = Base64.strict_decode64(psk)

      # cipher = OpenSSL::Cipher.new('AES-256-CTR')
      cipher = OpenSSL::Cipher.new('AES-128-CTR')
      mqtt_obj.get_packet do |packet_bytes|
        # puts "Packet Bytes: #{packet_bytes.public_methods}"
        raw_packet = packet_bytes.to_s.b
        raw_packet_len = raw_packet.to_s.b.length
        raw_topic = packet_bytes.topic
        raw_payload = packet_bytes.payload
        raw_payload_len = raw_payload.length

        begin
          puts '-' * 80

          payload = {}
          if json
            json_payload = JSON.parse(raw_payload, symbolize_names: true)
            payload = Meshtastic::ServiceEnvelope.json_decode(json_payload)
            map_report = Meshtastic::MapReport.json_decode(json_payload)
          else
            svc_envl= Meshtastic::ServiceEnvelope.decode(raw_payload)
            payload = svc_envl.to_h[:packet]
            # puts "STILL GOOD: #{payload.inspect}"
            # puts "Public Methods: #{Meshtastic::MapReport.public_methods}"
            # puts "Public Methods: #{Meshtastic::MapReport.class}"
            # map_report_decode = Meshtastic::MapReport.decode(raw_payload)
            # map_report = map_report_decode.to_h
            # puts "STILL GOOD: #{map_report.inspect}"
          end

          puts "*** MESSAGE ***"
          packet_from = payload[:from]
          puts "Packet From: #{packet_from}"
          packet_to = payload[:to]
          puts "Packet To: #{packet_to}"
          channel = payload[:channel]
          puts "Channel: #{channel}"
          packet_id = payload[:id]
          puts "Packet ID: #{packet_id}"
          puts "\nTopic: #{raw_topic}"

          decoded_payload = payload[:decoded]
          if decoded_payload
            port_num = decoded_payload[:portnum]
            puts "Port Number: #{port_num}"
            decp = decoded_payload[:payload].b
            puts "Decoded Payload: #{decp.inspect}"
            want_response = decoded_payload[:want_response]
            puts "Want Response: #{want_response}"
            dest = decoded_payload[:dest]
            puts "Destination: #{dest}"
            source = decoded_payload[:source]
            puts "Source: #{source}"
            request_id = decoded_payload[:request_id]
            puts "Request ID: #{request_id}"
            reply_id = decoded_payload[:reply_id]
            puts "Reply ID: #{reply_id}"
            emoji = decoded_payload[:emoji]
            puts "Emoji: #{emoji}"
          end

          encrypted_payload = payload[:encrypted]
          # If encrypted_payload is not nil, then decrypt the message
          if encrypted_payload.length.positive?
            nonce_packet_id = [packet_id].pack('V').ljust(8, "\x00")
            nonce_from_node = [packet_from].pack('V').ljust(8, "\x00")
            nonce = "#{nonce_packet_id}#{nonce_from_node}".b
            puts "Nonce: #{nonce.inspect} | Length: #{nonce.length}"

            # Decrypt the message
            # Key must be 32 bytes
            # IV mustr be 16 bytes
            cipher.decrypt
            cipher.key = dec_psk
            cipher.iv = nonce
            puts "\nEncrypted Payload:\n#{encrypted_payload.inspect}"
            puts "Length: #{encrypted_payload.length}" if encrypted_payload

            decrypted = cipher.update(encrypted_payload) + cipher.final
            puts "\nDecrypted Payload:\n#{decrypted.inspect}"
            puts "Length: #{decrypted.length}" if decrypted
          end
          puts '*' * 20

          # map_long_name = map_report[:long_name].b
          # puts "\n*** MAP STATS ***"
          # puts "Map Long Name: #{map_long_name.inspect}"
          # map_short_name = map_report[:short_name]
          # puts "Map Short Name: #{map_short_name}"
          # role = map_report[:role]
          # puts "Role: #{role}"
          # hw_model = map_report[:hw_model]
          # puts "Hardware Model: #{hw_model}"
          # firmware_version = map_report[:firmware_version]
          # puts "Firmware Version: #{firmware_version}"
          # region = map_report[:region]
          # puts "Region: #{region}"
          # modem_preset = map_report[:modem_preset]
          # puts "Modem Preset: #{modem_preset}"
          # has_default_channel = map_report[:has_default_channel]
          # puts "Has Default Channel: #{has_default_channel}"
          # latitiude_i = map_report[:latitude_i]
          # puts "Latitude: #{latitiude_i}"
          # longitude_i = map_report[:longitude_i]
          # puts "Longitude: #{longitude_i}"
          # altitude = map_report[:altitude]
          # puts "Altitude: #{altitude}"
          # position_precision = map_report[:position_precision]
          # puts "Position Precision: #{position_precision}"
          # num_online_local_nodes = map_report[:num_online_local_nodes]
          # puts "Number of Online Local Nodes: #{num_online_local_nodes}"
          # puts '*' * 20

          puts "\n*** PACKET DEBUGGING ***"
          puts "Payload: #{payload.inspect}"
          # puts "\nMap Report: #{map_report.inspect}"
          puts "\nRaw Packet: #{raw_packet.inspect}"
          puts "Length: #{raw_packet_len}"
          puts '*' * 20
        rescue Google::Protobuf::ParseError => e
          puts "ERROR: #{e.inspect}"
          puts "\n*** PACKET DEBUGGING ***"
          puts "Payload: #{payload.inspect}"
          # puts "\nMap Report: #{map_report.inspect}"
          puts "\nRaw Packet: #{raw_packet.inspect}"
          puts "Length: #{raw_packet_len}"
          puts '*' * 20
          next
        ensure
          puts '-' * 80
          puts "\n\n\n"
        end
      end
    rescue Interrupt
      puts "\nCTRL+C detected. Exiting..."
    rescue StandardError => e
      raise e
    ensure
      mqtt_obj.disconnect if mqtt_obj
    end

    # Supported Method Parameters::
    # mqtt_obj = Meshtastic.gps_search(
    #   lat: 'required - latitude float (e.g. 37.7749)',
    #   lon: 'required - longitude float (e.g. -122.4194)',
    # )
    public_class_method def self.gps_search(opts = {})
      lat = opts[:lat]
      lon = opts[:lon]

      raise 'ERROR: Latitude and Longitude are required' unless lat && lon

      gps_arr = [lat.to_f, lon.to_f]

      Geocoder.search(gps_arr)
    rescue StandardError => e
      raise e
    end

    # Supported Method Parameters::
    # mqtt_obj = Meshtastic.disconnect(
    #   mqtt_obj: 'required - mqtt_obj returned from #connect method'
    # )
    public_class_method def self.disconnect(opts = {})
      mqtt_obj = opts[:mqtt_obj]

      mqtt_obj.disconnect if mqtt_obj
      nil
    rescue StandardError => e
      raise e
    end

    # Author(s):: 0day Inc. <support@0dayinc.com>

    public_class_method def self.authors
      "AUTHOR(S):
        0day Inc. <support@0dayinc.com>
      "
    end

    # Display Usage for this Module

    public_class_method def self.help
      puts "USAGE:
        mqtt_obj = #{self}.connect(
          host: 'optional - mqtt host (default: mqtt.meshtastic.org)',
          port: 'optional - mqtt port (defaults: 1883)',
          username: 'optional - mqtt username (default: meshdev)',
          password: 'optional - (default: large4cats)'
        )

        #{self}.subscribe(
          mqtt_obj: 'required - mqtt_obj object returned from #connect method',
          region: 'optional - region (default: US)',
          channel: 'optional - channel name (default: LongFast)',
          psk: 'optional - channel pre-shared key (default: AQ==)',
          qos: 'optional - quality of service (default: 0)'
        )

        mqtt_obj = #{self}.disconnect(
          mqtt_obj: 'required - mqtt_obj object returned from #connect method'
        )

        #{self}.authors
      "
    end
  end
end
