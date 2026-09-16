# frozen_string_literal: true

require 'timeout'
require 'monitor'
require 'meshtastic/admin_pb'

module Meshtastic
  module Admin
    class RoutingError < StandardError
      attr_reader :reason, :request_id, :from

      def initialize(reason, request_id, from)
        @reason = reason
        @request_id = request_id
        @from = from
        super("Admin routing failure: #{reason} (request #{request_id})")
      end
    end

    SKIP = %i[
      message serial_obj bluetooth_obj tcp_obj mqtt_obj to from channel want_ack hop_limit
      want_response port_num data via psks seconds owner long_name short_name index config_type
      module_config_type path node_num lat lon altitude time channel_settings channel_pb
      config module_config messages ringtone scale location event event_code kb_char touch_x
      touch_y ham call_sign tx_power frequency position ui_config contact value preserve_favorites
      last_packet_id pki_encrypted public_key topic qos retained timeout auto_session refresh_session
    ].freeze
    PAYLOAD_FIELDS = Meshtastic::AdminMessage.descriptor.lookup_oneof('payload_variant').map { |field| field.name.to_sym }.freeze

    public_class_method def self.encode(opts = {})
      original = opts[:message] || Meshtastic::AdminMessage.new
      raise ArgumentError, 'message must be an AdminMessage' unless original.is_a?(Meshtastic::AdminMessage)

      fields = opts.keys & PAYLOAD_FIELDS
      variants = (fields + [original.payload_variant]).compact.uniq
      raise ArgumentError, 'exactly one payload is required' unless variants.length == 1

      unknown = opts.keys - SKIP - PAYLOAD_FIELDS - [:session_passkey]
      raise ArgumentError, "unknown admin options: #{unknown.join(', ')}" unless unknown.empty?

      message = Meshtastic::AdminMessage.decode(original.to_proto)
      fields.each do |key|
        raise ArgumentError, "#{key} cannot be nil" if opts[key].nil?

        message.public_send("#{key}=", opts[key])
      end
      if opts.key?(:session_passkey)
        passkey = opts[:session_passkey]
        raise ArgumentError, 'session_passkey must contain exactly eight bytes' unless passkey.is_a?(String) && passkey.bytesize == 8

        message.session_passkey = passkey
      end
      message
    end

    public_class_method def self.send(opts = {})
      message = encode(opts)
      connection = opts[:serial_obj] || opts[:bluetooth_obj] || opts[:tcp_obj]
      destination = opts[:to] || connection&.dig(:my_node_num)
      destination = destination.delete_prefix('!').to_i(16) if destination.is_a?(String) && destination.match?(/\A![0-9a-fA-F]{8}\z/)
      raise ArgumentError, 'an explicit unicast destination or connected my_node_num is required' unless destination.is_a?(Integer) && destination.between?(1, 0xfffffffe)

      if opts.fetch(:auto_session, true) && message.session_passkey.empty? && destination != connection&.dig(:my_node_num) &&
         !message.payload_variant.to_s.match?(/\Aget_.*_(request|response)\z/)
        message.session_passkey = acquire_session(opts.merge(connection: connection, target: destination))
      end
      want_response = opts.fetch(:want_response) { message.payload_variant.to_s.match?(/\Aget_.*_request\z/) }
      data = Meshtastic::Data.new(
        portnum: :ADMIN_APP,
        payload: message.to_proto,
        want_response: want_response
      )
      delivery = opts.merge(data: data, port_num: Meshtastic::PortNum::ADMIN_APP, to: destination)
      delivery[:from] = 0 if connection && !opts.key?(:from)
      Meshtastic.deliver_data(delivery)
    end

    public_class_method def self.request(opts = {})
      request_id = opts.fetch(:request_id) { Random.rand(2..0xffffffff) }
      raise ArgumentError, 'request_id must be an Integer from 2 through 0xffffffff' unless request_id.is_a?(Integer) && request_id.between?(2, 0xffffffff)

      options = opts.except(:request_id, :wait)
      return { request_id: request_id, result: send(options.merge(last_packet_id: request_id - 1)) } unless opts.fetch(:wait, true)

      connection = options[:serial_obj] || options[:bluetooth_obj] || options[:tcp_obj]
      queue = connection && connection[:from_radio_queue]
      raise ArgumentError, 'synchronous Admin requires a connected radio receive queue' unless queue

      timeout = opts.fetch(:timeout, 10)
      raise ArgumentError, 'timeout must be a positive finite number' unless timeout.is_a?(Numeric) && timeout.positive? && timeout.finite?

      lock = connection[:admin_request_lock] ||= Monitor.new
      acquired = lock.try_enter
      raise IOError, 'a synchronous Admin request is already active on this handle' unless acquired

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      message = encode(options)
      target = options.fetch(:to, connection[:my_node_num])
      target = target.delete_prefix('!').to_i(16) if target.is_a?(String) && target.match?(/\A![0-9a-fA-F]{8}\z/)
      result = send(options.merge(last_packet_id: request_id - 1, want_response: true, want_ack: true, timeout: timeout))
      variant = message.payload_variant.to_s
      expected = variant.match?(/\Aget_.*_request\z/) ? variant.sub(/_request\z/, '_response').to_sym : :routing
      reply = await_response(connection: connection, queue: queue, deadline: deadline, request_id: request_id, target: target,
                             variant: expected)
      if reply[:session_passkey]&.bytesize == 8
        sessions = connection[:admin_sessions] ||= {}
        sessions[target] = { key: reply[:session_passkey], expires_at: deadline - timeout + 150 }
      end
      reply.merge(result: result)
    rescue RoutingError => e
      connection[:admin_sessions]&.delete(target) if connection && e.reason == :ADMIN_BAD_SESSION_KEY
      raise
    ensure
      lock.exit if acquired
    end

    private_class_method def self.acquire_session(opts = {})
      connection = opts[:connection]
      raise ArgumentError, 'automatic Admin sessions require a radio receive queue; supply session_passkey for MQTT' unless connection && connection[:from_radio_queue]

      sessions = connection[:admin_sessions] ||= {}
      cached = sessions[opts[:target]]
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return cached[:key] if cached && now < cached[:expires_at] && !opts[:refresh_session]

      sessions.delete(opts[:target])
      options = opts.except(*(PAYLOAD_FIELDS + %i[message connection target session_passkey refresh_session last_packet_id]))
      reply = request(options.merge(get_config_request: :SESSIONKEY_CONFIG, auto_session: false))
      key = reply[:session_passkey]
      raise ArgumentError, 'Admin session response did not contain an eight-byte passkey' unless key.bytesize == 8

      sessions[opts[:target]] = { key: key, expires_at: now + 150 }
      key
    end

    private_class_method def self.await_response(opts = {})
      queue = opts[:queue]
      deferred = []
      loop do
        remaining = opts[:deadline] - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout::Error, 'Admin response timed out' unless remaining.positive?

        incoming = queue.pop(timeout: remaining)
        raise Timeout::Error, 'Admin response timed out or transport closed' unless incoming

        packet = incoming.is_a?(Meshtastic::FromRadio) ? incoming.packet : incoming
        if packet.is_a?(Meshtastic::MeshPacket) && packet.decoded&.portnum == :ROUTING_APP && packet.decoded.request_id == opts[:request_id] &&
           [opts[:target], opts[:connection][:my_node_num]].include?(packet.from)
          reason = Meshtastic::Routing.decode(packet.decoded.payload).error_reason
          raise RoutingError.new(reason, opts[:request_id], packet.from) if reason != :NONE && [opts[:target], opts[:connection][:my_node_num]].include?(packet.from)
          return { variant: :routing, value: reason, request_id: opts[:request_id], from: packet.from } if reason == :NONE && packet.from == opts[:target] && opts[:variant] == :routing
        end
        reply = response(packet: incoming, request_id: opts[:request_id], from: opts[:target])
        return reply if reply && reply[:variant] == opts[:variant]

        deferred << incoming
      end
    ensure
      begin
        until deferred.nil? || deferred.empty?
          queue << deferred.first
          deferred.shift
        end
      rescue ClosedQueueError
        replacement = Queue.new
        deferred.each { |incoming| replacement << incoming }
        while (incoming = queue.pop)
          replacement << incoming
        end
        replacement.close
        opts[:connection][:from_radio_queue] = replacement
        deferred.clear
      end
    end

    public_class_method def self.decode(opts = {})
      packet = opts[:packet]
      packet = packet.packet if packet.is_a?(Meshtastic::FromRadio)
      data = packet.is_a?(Meshtastic::MeshPacket) ? packet.decoded : packet
      raise ArgumentError, 'packet must contain decoded ADMIN_APP data' if opts.key?(:packet) && (!data.is_a?(Meshtastic::Data) || data.portnum != :ADMIN_APP)

      payload = data ? data.payload : opts[:payload]
      raise ArgumentError, 'payload bytes or a decoded packet are required' unless payload.is_a?(String)

      Meshtastic::AdminMessage.decode(payload)
    end

    public_class_method def self.response(opts = {})
      packet = opts[:packet]
      packet = packet.packet if packet.is_a?(Meshtastic::FromRadio)
      return nil unless packet.is_a?(Meshtastic::MeshPacket) && packet.decoded&.portnum == :ADMIN_APP
      return nil if opts.key?(:request_id) && packet.decoded.request_id != opts[:request_id]
      return nil if opts.key?(:from) && packet.from != opts[:from]

      message = decode(packet: packet)
      variant = message.payload_variant
      return nil unless variant.to_s.end_with?('_response')

      {
        message: message, variant: variant, value: message.public_send(variant),
        session_passkey: message.session_passkey, request_id: packet.decoded.request_id, from: packet.from
      }
    end

    public_class_method def self.reboot(opts = {})
      send(opts.merge(reboot_seconds: opts[:seconds] || 5))
    end

    public_class_method def self.shutdown(opts = {})
      send(opts.merge(shutdown_seconds: opts[:seconds] || 5))
    end

    public_class_method def self.reboot_ota(opts = {})
      send(opts.merge(reboot_ota_seconds: opts[:seconds] || 5))
    end

    public_class_method def self.ota_request(opts = {})
      send(opts.merge(ota_request: opts[:event]))
    end

    public_class_method def self.set_owner(opts = {})
      user = opts[:owner] || Meshtastic::User.new(long_name: opts[:long_name], short_name: opts[:short_name])
      send(opts.merge(set_owner: user))
    end

    public_class_method def self.get_owner(opts = {})
      send(opts.merge(get_owner_request: true))
    end

    public_class_method def self.set_channel(opts = {})
      send(opts.merge(set_channel: opts[:channel_settings] || opts[:channel_pb]))
    end

    public_class_method def self.get_channel(opts = {})
      index = opts[:index]
      index = 0 if index.nil?
      raise ArgumentError, 'index must be an Integer from 0 through 7' unless index.is_a?(Integer) && index.between?(0, 7)

      send(opts.merge(get_channel_request: index + 1))
    end

    public_class_method def self.get_config(opts = {})
      send(opts.merge(get_config_request: opts[:config_type] || :DEVICE_CONFIG))
    end

    public_class_method def self.set_config(opts = {})
      send(opts.merge(set_config: opts[:config]))
    end

    public_class_method def self.get_module_config(opts = {})
      send(opts.merge(get_module_config_request: opts[:module_config_type] || :MQTT_CONFIG))
    end

    public_class_method def self.set_module_config(opts = {})
      send(opts.merge(set_module_config: opts[:module_config]))
    end

    public_class_method def self.get_canned_messages(opts = {})
      send(opts.merge(get_canned_message_module_messages_request: true))
    end

    public_class_method def self.set_canned_messages(opts = {})
      send(opts.merge(set_canned_message_module_messages: opts[:messages]))
    end

    public_class_method def self.get_device_metadata(opts = {})
      send(opts.merge(get_device_metadata_request: true))
    end

    public_class_method def self.get_ringtone(opts = {})
      send(opts.merge(get_ringtone_request: true))
    end

    public_class_method def self.set_ringtone(opts = {})
      send(opts.merge(set_ringtone_message: opts[:ringtone]))
    end

    public_class_method def self.get_device_connection_status(opts = {})
      send(opts.merge(get_device_connection_status_request: true))
    end

    public_class_method def self.get_node_remote_hardware_pins(opts = {})
      send(opts.merge(get_node_remote_hardware_pins_request: true))
    end

    public_class_method def self.enter_dfu(opts = {})
      send(opts.merge(enter_dfu_mode_request: true))
    end

    public_class_method def self.delete_file(opts = {})
      send(opts.merge(delete_file_request: opts[:path]))
    end

    public_class_method def self.set_scale(opts = {})
      send(opts.merge(set_scale: opts[:scale]))
    end

    public_class_method def self.backup_preferences(opts = {})
      send(opts.merge(backup_preferences: opts[:location] || :FLASH))
    end

    public_class_method def self.restore_preferences(opts = {})
      send(opts.merge(restore_preferences: opts[:location] || :FLASH))
    end

    public_class_method def self.remove_backup_preferences(opts = {})
      send(opts.merge(remove_backup_preferences: opts[:location] || :FLASH))
    end

    public_class_method def self.send_input_event(opts = {})
      event = opts[:event] || Meshtastic::AdminMessage::InputEvent.new(
        event_code: opts[:event_code].to_i,
        kb_char: opts[:kb_char].to_i,
        touch_x: opts[:touch_x].to_i,
        touch_y: opts[:touch_y].to_i
      )
      send(opts.merge(send_input_event: event))
    end

    public_class_method def self.set_ham_mode(opts = {})
      ham = opts[:ham] || Meshtastic::HamParameters.new(
        call_sign: opts[:call_sign].to_s,
        tx_power: opts[:tx_power].to_i,
        frequency: opts[:frequency].to_f,
        short_name: opts[:short_name].to_s,
        long_name: opts[:long_name].to_s
      )
      send(opts.merge(set_ham_mode: ham))
    end

    public_class_method def self.remove_by_nodenum(opts = {})
      send(opts.merge(remove_by_nodenum: opts[:node_num]))
    end

    public_class_method def self.set_favorite_node(opts = {})
      send(opts.merge(set_favorite_node: opts[:node_num]))
    end

    public_class_method def self.remove_favorite_node(opts = {})
      send(opts.merge(remove_favorite_node: opts[:node_num]))
    end

    public_class_method def self.set_fixed_position(opts = {})
      position = opts[:position] || Meshtastic::Position.build(lat: opts[:lat], lon: opts[:lon], altitude: opts[:altitude])
      send(opts.merge(set_fixed_position: position))
    end

    public_class_method def self.remove_fixed_position(opts = {})
      send(opts.merge(remove_fixed_position: true))
    end

    public_class_method def self.set_time(opts = {})
      send(opts.merge(set_time_only: opts[:time]))
    end

    public_class_method def self.get_ui_config(opts = {})
      send(opts.merge(get_ui_config_request: true))
    end

    public_class_method def self.store_ui_config(opts = {})
      send(opts.merge(store_ui_config: opts[:ui_config]))
    end

    public_class_method def self.set_ignored_node(opts = {})
      send(opts.merge(set_ignored_node: opts[:node_num]))
    end

    public_class_method def self.remove_ignored_node(opts = {})
      send(opts.merge(remove_ignored_node: opts[:node_num]))
    end

    public_class_method def self.toggle_muted_node(opts = {})
      send(opts.merge(toggle_muted_node: opts[:node_num]))
    end

    public_class_method def self.begin_edit(opts = {})
      send(opts.merge(begin_edit_settings: true))
    end

    public_class_method def self.commit_edit(opts = {})
      send(opts.merge(commit_edit_settings: true))
    end

    public_class_method def self.add_contact(opts = {})
      send(opts.merge(add_contact: opts[:contact]))
    end

    public_class_method def self.key_verification(opts = {})
      send(opts.merge(key_verification: opts[:key_verification]))
    end

    public_class_method def self.factory_reset_device(opts = {})
      send(opts.merge(factory_reset_device: opts[:value] || 1))
    end

    public_class_method def self.factory_reset_config(opts = {})
      send(opts.merge(factory_reset_config: opts[:value] || 1))
    end

    public_class_method def self.nodedb_reset(opts = {})
      send(opts.merge(nodedb_reset: opts.fetch(:preserve_favorites, true)))
    end

    public_class_method def self.exit_simulator(opts = {})
      send(opts.merge(exit_simulator: true))
    end

    public_class_method def self.sensor_config(opts = {})
      send(opts.merge(sensor_config: opts[:sensor_config]))
    end

    public_class_method def self.lockdown_auth(opts = {})
      send(opts.merge(lockdown_auth: opts[:lockdown_auth]))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "USAGE:
        # Encode exactly one AdminMessage payload without modifying the caller.
        #{self}.encode(
          message: 'optional - existing AdminMessage to copy instead of a new one',
          session_passkey: 'optional - bytes from a prior get_*_response to authorize sets'
        )

        # Send an AdminMessage on ADMIN_APP over a connected transport.
        #{self}.send(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          bluetooth_obj: 'optional - BLE handle from Meshtastic::Bluetooth.connect',
          tcp_obj: 'optional - TCP handle from Meshtastic::TCP.connect',
          mqtt_obj: 'optional - MQTT client from Meshtastic::MQTT.connect',
          to: 'optional - unicast node integer or !eighthex; defaults to connected my_node_num; required for MQTT',
          from: 'optional - sender number; radio default zero denotes the local PhoneAPI client',
          channel: 'optional - routing channel index (default zero)',
          want_ack: 'optional - request routing acknowledgment, distinct from an admin reply',
          hop_limit: 'optional - maximum radio hop count',
          psks: 'optional - MQTT channel key map; not public-key admin authorization',
          pki_encrypted: 'optional - enable device-owned PKI on serial BLE or TCP; unsupported over MQTT',
          public_key: 'optional - recipient public-key bytes for radio PKI',
          last_packet_id: 'optional - previous packet number used by transport packet generation',
          want_response: 'optional - defaults true for get requests and false for state changes',
          auto_session: 'optional - acquire a session for remote writes unless a passkey is supplied (default true)',
          refresh_session: 'optional - discard cached session for this automatic acquisition (default false)',
          timeout: 'optional - positive finite receive deadline in seconds for session acquisition (default ten)'
        )

        # Send admin data and synchronously await correlated readback.
        #{self}.request(
          request_id: 'optional - packet ID from 2 through 0xffffffff; generated when omitted; accepts send options',
          wait: 'optional - false returns only request_id and submission result; true waits for reply (default true)',
          timeout: 'optional - positive finite total response budget in seconds including session acquisition (default ten)'
        )

        # Decode protobuf bytes or an incoming admin packet.
        #{self}.decode(
          payload: 'optional - serialized AdminMessage bytes when packet is omitted',
          packet: 'optional - FromRadio MeshPacket or Data containing decoded ADMIN_APP bytes'
        )

        # Extract a matching response and its session passkey.
        #{self}.response(
          packet: 'required - incoming FromRadio or MeshPacket protobuf',
          request_id: 'optional - require this Data.request_id to match the outgoing packet ID',
          from: 'optional - require this numeric responding node; mismatches return nil'
        )

        # Request legacy ESP32 OTA reboot; deprecated firmware operation.
        #{self}.reboot_ota(
          seconds: 'optional - legacy reboot delay, negative cancels (default five); use ota_request on current firmware'
        )

        # Send the current OTA loader request protobuf.
        #{self}.ota_request(
          event: 'required - AdminMessage::OTAEvent containing mode and firmware hash; see Admin::Firmware'
        )

        # Reboot the node after a delay.
        #{self}.reboot(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          seconds: 'optional - delay before reboot in seconds (default: 5)'
        )

        # Shut down the node after a delay.
        #{self}.shutdown(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          seconds: 'optional - delay before shutdown in seconds (default: 5)'
        )

        # Set the node owner User protobuf.
        #{self}.set_owner(
          owner: 'optional - Meshtastic::User protobuf to send as set_owner',
          long_name: 'optional - owner long name when owner is omitted',
          short_name: 'optional - owner short name when owner is omitted'
        )

        # Request the node owner User protobuf.
        #{self}.get_owner(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Write a Channel protobuf to the node.
        #{self}.set_channel(
          channel_settings: 'optional - Meshtastic::Channel protobuf to write',
          channel_pb: 'optional - Channel protobuf alias used as set_channel'
        )

        # Request a channel by index.
        #{self}.get_channel(
          index: 'optional - zero-based channel index 0 through 7; wire conversion happens here (default zero)'
        )

        # Request a radio Config section.
        #{self}.get_config(
          config_type: 'optional - AdminMessage::ConfigType such as :LORA_CONFIG'
        )

        # Write a Config protobuf to the node.
        #{self}.set_config(
          config: 'required - Meshtastic::Config protobuf to write'
        )

        # Request a ModuleConfig section.
        #{self}.get_module_config(
          module_config_type: 'optional - ModuleConfigType such as :MQTT_CONFIG'
        )

        # Write a ModuleConfig protobuf to the node.
        #{self}.set_module_config(
          module_config: 'required - Meshtastic::ModuleConfig protobuf to write'
        )

        # Request canned-message module strings.
        #{self}.get_canned_messages(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Set canned-message module strings.
        #{self}.set_canned_messages(
          messages: 'required - pipe-separated canned message text; empty string clears it'
        )

        # Request DeviceMetadata (firmware version and hardware).
        #{self}.get_device_metadata(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Request the RTTTL ringtone string.
        #{self}.get_ringtone(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Set the RTTTL ringtone string.
        #{self}.set_ringtone(
          ringtone: 'required - RTTTL ringtone text to store on the node'
        )

        # Request DeviceConnectionStatus.
        #{self}.get_device_connection_status(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Request remote-hardware pin definitions.
        #{self}.get_node_remote_hardware_pins(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Ask the node to enter DFU / UF2 mode.
        #{self}.enter_dfu(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Delete a file on the node filesystem.
        #{self}.delete_file(
          path: 'required - filesystem path on the node to delete'
        )

        # Set the NAU7802 scale calibration value.
        #{self}.set_scale(
          scale: 'required - integer scale factor for the NAU7802 module'
        )

        # Backup preferences to flash or SD.
        #{self}.backup_preferences(
          location: 'optional - :FLASH or :SD backup location (default: :FLASH)'
        )

        # Restore preferences from flash or SD.
        #{self}.restore_preferences(
          location: 'optional - :FLASH or :SD backup location (default: :FLASH)'
        )

        # Remove a preferences backup from flash or SD.
        #{self}.remove_backup_preferences(
          location: 'optional - :FLASH or :SD backup location (default: :FLASH)'
        )

        # Inject a device-UI input event.
        #{self}.send_input_event(
          event: 'optional - AdminMessage::InputEvent protobuf to send',
          event_code: 'optional - input event code when event is omitted',
          kb_char: 'optional - keyboard character code when event is omitted',
          touch_x: 'optional - touch X coordinate when event is omitted',
          touch_y: 'optional - touch Y coordinate when event is omitted'
        )

        # Enable ham-radio identity parameters.
        #{self}.set_ham_mode(
          ham: 'optional - HamParameters protobuf to send',
          call_sign: 'optional - amateur callsign when ham is omitted',
          tx_power: 'optional - transmit power when ham is omitted',
          frequency: 'optional - frequency in MHz when ham is omitted',
          short_name: 'optional - short name when ham is omitted',
          long_name: 'optional - long name when ham is omitted'
        )

        # Remove a node from the local nodedb by number.
        #{self}.remove_by_nodenum(
          node_num: 'required - node number to remove from the nodedb'
        )

        # Mark a node as a favorite.
        #{self}.set_favorite_node(
          node_num: 'required - node number to mark as favorite'
        )

        # Clear favorite status for a node.
        #{self}.remove_favorite_node(
          node_num: 'required - node number to unfavorite'
        )

        # Set a fixed GPS position on the node.
        #{self}.set_fixed_position(
          position: 'optional - Meshtastic::Position protobuf to store',
          lat: 'optional - latitude in decimal degrees when position is omitted',
          lon: 'optional - longitude in decimal degrees when position is omitted',
          altitude: 'optional - altitude in meters when position is omitted'
        )

        # Clear the fixed GPS position on the node.
        #{self}.remove_fixed_position(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Set node wall-clock time.
        #{self}.set_time(
          time: 'required - unix timestamp to set on the node'
        )

        # Request DeviceUIConfig.
        #{self}.get_ui_config(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Store DeviceUIConfig on the node.
        #{self}.store_ui_config(
          ui_config: 'required - Meshtastic::DeviceUIConfig protobuf to store'
        )

        # Ignore a node number.
        #{self}.set_ignored_node(
          node_num: 'required - node number to ignore'
        )

        # Stop ignoring a node number.
        #{self}.remove_ignored_node(
          node_num: 'required - node number to stop ignoring'
        )

        # Toggle mute for a node number.
        #{self}.toggle_muted_node(
          node_num: 'required - node number whose mute flag should toggle'
        )

        # Open a settings edit transaction.
        #{self}.begin_edit(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Commit a settings edit transaction.
        #{self}.commit_edit(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Add a SharedContact to the node.
        #{self}.add_contact(
          contact: 'required - Meshtastic::SharedContact protobuf to add'
        )

        # Send a KeyVerificationAdmin protobuf.
        #{self}.key_verification(
          key_verification: 'required - KeyVerificationAdmin protobuf to send'
        )

        # Factory-reset device state including BLE bonds.
        #{self}.factory_reset_device(
          value: 'optional - int32 factory_reset_device field (default: 1)'
        )

        # Factory-reset configuration only.
        #{self}.factory_reset_config(
          value: 'optional - int32 factory_reset_config field (default: 1)'
        )

        # Clear the node database.
        #{self}.nodedb_reset(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          preserve_favorites: 'optional - retain favorite nodes (default true); some firmware roles always preserve favorites'
        )

        # Exit the firmware simulator if running.
        #{self}.exit_simulator(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
        )

        # Write a SensorConfig protobuf.
        #{self}.sensor_config(
          sensor_config: 'required - Meshtastic::SensorConfig protobuf to write'
        )

        # Send lockdown authentication material.
        #{self}.lockdown_auth(
          lockdown_auth: 'required - Meshtastic::LockdownAuth protobuf to send'
        )

        # Print the AUTHOR(S) string for this module.
        #{self}.authors
      "
    end
  end
end

require 'meshtastic/admin/firmware'
require 'meshtastic/admin/channel'
require 'meshtastic/admin/config'
