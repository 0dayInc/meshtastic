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
    #   json: 'optional - JSON output (default: false)',
    #   filter: 'optional - comma-delimited string(s) to search for in the payload (default: nil)'
    # )

    public_class_method def self.subscribe(opts = {})
      mqtt_obj = opts[:mqtt_obj]
      region = opts[:region] ||= 'US'
      channel = opts[:channel] ||= 'LongFast'
      psk = opts[:psk] ||= 'AQ=='
      qos = opts[:qos] ||= 0
      json = opts[:json] ||= false
      filter = opts[:filter]

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
      filter_arr = filter.to_s.split(',').map(&:strip)
      mqtt_obj.get_packet do |packet_bytes|
        raw_packet = packet_bytes.to_s.b
        raw_packet_len = raw_packet.to_s.b.length
        raw_topic = packet_bytes.topic
        raw_payload = packet_bytes.payload

        begin
          payload = {}
          if json
            payload = JSON.parse(raw_payload, symbolize_names: true)
          else
            svc_envl = Meshtastic::ServiceEnvelope.decode(raw_payload)
            # map_report = Meshtastic::MapReport.decode(raw_payload)
            payload = svc_envl.to_h[:packet]
          end
          payload[:topic] = raw_topic
          payload[:node_id_from] = "!#{payload[:from].to_i.to_s(16)}"
          payload[:node_id_to] = "!#{payload[:to].to_i.to_s(16)}"

          encrypted_payload = payload[:encrypted]
          # If encrypted_payload is not nil, then decrypt the message
          if encrypted_payload.length.positive?
            packet_id = payload[:id]
            packet_from = payload[:from]
            nonce_packet_id = [packet_id].pack('V').ljust(8, "\x00")
            nonce_from_node = [packet_from].pack('V').ljust(8, "\x00")
            nonce = "#{nonce_packet_id}#{nonce_from_node}".b

            # Decrypt the message
            # Key must be 32 bytes
            # IV mustr be 16 bytes
            cipher.decrypt
            cipher.key = dec_psk
            cipher.iv = nonce

            decrypted = cipher.update(encrypted_payload) + cipher.final
            payload[:decrypted] = decrypted
          end

          filter_arr = [payload[:id].to_s] if filter.nil?
          disp = false
          flat_payload = payload.values.join(' ')

          disp = true if filter_arr.first == payload[:id] ||
                         filter_arr.all? { |filter| flat_payload.include?(filter) }

          if disp
            puts "\n"
            puts '-' * 80
            puts "\n*** DEBUGGING ***"
            puts "Payload:\n#{payload}"
            # puts "\nMap Report: #{map_report.inspect}"
            puts "\nRaw Packet: #{raw_packet.inspect}"
            puts "Length: #{raw_packet_len}"
            puts '-' * 80
            puts "\n\n\n"
          else
            print '.'
          end
        rescue Google::Protobuf::ParseError
          puts "\n"
          puts '-' * 80
          puts "\n*** DEBUGGING ***"
          puts "Payload:\n#{payload}"
          # puts "\nMap Report: #{map_report.inspect}"
          puts "\nRaw Packet: #{raw_packet.inspect}"
          puts "Length: #{raw_packet_len}"
          puts '-' * 80
          puts "\n\n\n"
          next
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
