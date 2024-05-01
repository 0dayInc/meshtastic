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
    #   root_topic: 'optional - root topic (default: msh)',
    #   region: 'optional - region (default: US)',
    #   channel: 'optional - channel name (default: LongFast)',
    #   psk: 'optional - channel pre-shared key (default: AQ==)',
    #   qos: 'optional - quality of service (default: 0)',
    #   json: 'optional - JSON output (default: false)',
    #   filter: 'optional - comma-delimited string(s) to filter on in message (default: nil)',
    #   gps_metadata: 'optional - include GPS metadata in output (default: false)'
    # )

    public_class_method def self.subscribe(opts = {})
      mqtt_obj = opts[:mqtt_obj]
      root_topic = opts[:root_topic] ||= 'msh'
      region = opts[:region] ||= 'US'
      channel = opts[:channel] ||= 'LongFast'
      psk = opts[:psk] ||= 'AQ=='
      qos = opts[:qos] ||= 0
      json = opts[:json] ||= false
      filter = opts[:filter]
      gps_metadata = opts[:gps_metadata] ||= false

      # TODO: Find JSON URI for this
      full_topic = "#{root_topic}/#{region}/2/json/#{channel}/#" if json
      full_topic = "#{root_topic}/#{region}/2/c/#{channel}/#" unless json
      puts "Subscribing to: #{full_topic}"
      mqtt_obj.subscribe(full_topic, qos)

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
        raw_topic = packet_bytes.topic ||= ''
        raw_message = packet_bytes.payload

        begin
          disp = false
          message = {}
          stdout_message = ''

          if json
            message = JSON.parse(raw_message, symbolize_names: true)
          else
            decoded_packet = Meshtastic::ServiceEnvelope.decode(raw_message)
            message = decoded_packet.to_h[:packet]
          end
          message[:topic] = raw_topic
          message[:node_id_from] = "!#{message[:from].to_i.to_s(16)}"
          message[:node_id_to] = "!#{message[:to].to_i.to_s(16)}"

          encrypted_message = message[:encrypted]
          # If encrypted_message is not nil, then decrypt the message
          if encrypted_message.to_s.length.positive?
            packet_id = message[:id]
            packet_from = message[:from]
            nonce_packet_id = [packet_id].pack('V').ljust(8, "\x00")
            nonce_from_node = [packet_from].pack('V').ljust(8, "\x00")
            nonce = "#{nonce_packet_id}#{nonce_from_node}".b

            # Decrypt the message
            # Key must be 32 bytes
            # IV mustr be 16 bytes
            cipher.decrypt
            cipher.key = dec_psk
            cipher.iv = nonce

            decrypted = cipher.update(encrypted_message) + cipher.final
            message[:decrypted] = decrypted
            # Vvv Decode the decrypted message vvV
          end

          if message[:decoded]
            payload = message[:decoded][:payload]

            msg_type = message[:decoded][:portnum]
            case msg_type
            when :ADMIN_APP
              pb_obj = Meshtastic::AdminMessage.decode(payload)
            when :ATAK_FORWARDER, :ATAK_PLUGIN
              pb_obj = Meshtastic::TAKPacket.decode(payload)
              # when :AUDIO_APP
              # pb_obj = Meshtastic::Audio.decode(payload)
            when :DETECTION_SENSOR_APP
              pb_obj = Meshtastic::DeviceState.decode(payload)
              # when :IP_TUNNEL_APP
              # pb_obj = Meshtastic::IpTunnel.decode(payload)
            when :MAP_REPORT_APP
              pb_obj = Meshtastic::MapReport.decode(payload)
              # when :MAX
              # pb_obj = Meshtastic::Max.decode(payload)
            when :NEIGHBORINFO_APP
              pb_obj = Meshtastic::NeighborInfo.decode(payload)
            when :NODEINFO_APP
              pb_obj = Meshtastic::User.decode(payload)
            when :PAXCOUNTER_APP
              pb_obj = Meshtastic::Paxcount.decode(payload)
            when :POSITION_APP
              pb_obj = Meshtastic::Position.decode(payload)
              # when :PRIVATE_APP
              # pb_obj = Meshtastic::Private.decode(payload)
            when :RANGE_TEST_APP
              # Unsure if this is the correct protobuf object
              pb_obj = Meshtastic::FromRadio.decode(payload)
            when :REMOTE_HARDWARE_APP
              pb_obj = Meshtastic::HardwareMessage.decode(payload)
              # when :REPLY_APP
              # pb_obj = Meshtastic::Reply.decode(payload)
            when :ROUTING_APP
              pb_obj = Meshtastic::Routing.decode(payload)
            when :SERIAL_APP
              pb_obj = Meshtastic::SerialConnectionStatus.decode(payload)
            when :SIMULATOR_APP,
                 :TEXT_MESSAGE_COMPRESSED_APP
              # Unsure if this is the correct protobuf object
              # for TEXT_MESSAGE_COMPRESSED_APP
              pb_obj = Meshtastic::Compressed.decode(payload)
            when :STORE_FORWARD_APP
              pb_obj = Meshtastic::StoreAndForward.decode(payload)
            when :TEXT_MESSAGE_APP
              # Unsure if this is the correct protobuf object
              pb_obj = Meshtastic::MqttClientProxyMessage.decode(payload)
            when :TELEMETRY_APP
              pb_obj = Meshtastic::Telemetry.decode(payload)
            when :TRACEROUTE_APP
              pb_obj = Meshtastic::RouteDiscovery.decode(payload)
              # when :UNKNOWN_APP
              # pb_obj = Meshtastic.Unknown.decode(payload)
            when :WAYPOINT_APP
              pb_obj = Meshtastic::Waypoint.decode(payload)
              # when :ZPS_APP
              # pb_obj = Meshtastic::Zps.decode(payload)
            else
              puts "WARNING: Unknown message type: #{msg_type}"
            end
            # Overwrite the payload with the decoded protobuf object
            # message[:decoded][:payload] = pb_obj.to_h unless msg_type == :TRACEROUTE_APP
            message[:decoded][:payload] = pb_obj.to_h
            if message[:decoded][:payload].keys.include?(:latitude_i) &&
               message[:decoded][:payload].keys.include?(:longitude_i) &&
               gps_metadata

              latitude = pb_obj.to_h[:latitude_i] * 0.0000001
              longitude = pb_obj.to_h[:longitude_i] * 0.0000001
              message[:decoded][:payload][:gps_metadata] = gps_search(
                lat: latitude,
                lon: longitude
              ).first.data
            end

            # If we there's a mac address, make it look like one.
            if message[:decoded][:payload].keys.include?(:macaddr)
              macaddr = message[:decoded][:payload][:macaddr]
              macaddr_fmt = macaddr.bytes.map { |byte| byte.to_s(16).rjust(2, '0') }.join(':')
              message[:decoded][:payload][:macaddr] = macaddr_fmt
            end
            # puts pb_obj.public_methods
            # message[:decoded][:pb_obj] = pb_obj
          end

          filter_arr = [message[:id].to_s] if filter.nil?
          flat_message = message.values.join(' ')

          disp = true if filter_arr.first == message[:id] ||
                         filter_arr.all? { |filter| flat_message.include?(filter) }

          message[:raw_packet] = raw_packet if block_given?
          stdout_message = JSON.pretty_generate(message) unless block_given?
        rescue Google::Protobuf::ParseError,
               JSON::GeneratorError

          stdout_message = message.inspect unless block_given?
          next
        ensure
          if disp
            if block_given?
              yield message
            else
              puts "\n"
              puts '-' * 80
              puts 'MSG:'
              puts stdout_message
              puts '-' * 80
              puts "\n\n\n"
            end
          else
            print '.'
          end
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
          root_topic: 'optional - root topic (default: msh)',
          region: 'optional - region (default: US)',
          channel: 'optional - channel name (default: LongFast)',
          psk: 'optional - channel pre-shared key (default: AQ==)',
          qos: 'optional - quality of service (default: 0)',
          json: 'optional - JSON output (default: false)',
          filter: 'optional - comma-delimited string(s) to filter on in message (default: nil)',
          gps_metadata: 'optional - include GPS metadata in output (default: false)'
        )

        #{self}.gps_search(
          lat: 'required - latitude float (e.g. 37.7749)',
          lon: 'required - longitude float (e.g. -122.4194)',
        )

        mqtt_obj = #{self}.disconnect(
          mqtt_obj: 'required - mqtt_obj object returned from #connect method'
        )

        #{self}.authors
      "
    end
  end
end
