# frozen_string_literal: true

require 'meshtastic/admin_pb'

module Meshtastic
  module Admin
    SKIP = %i[
      message serial_obj bluetooth_obj tcp_obj mqtt_obj to from channel want_ack hop_limit
      want_response port_num data via psks seconds owner long_name short_name index config_type
      module_config_type path node_num lat lon altitude time
    ].freeze

    public_class_method def self.encode(opts = {})
      message = opts[:message] || Meshtastic::AdminMessage.new
      opts.each do |key, value|
        next if SKIP.include?(key)
        next unless message.respond_to?("#{key}=")

        message.public_send("#{key}=", value)
      end
      message
    end

    public_class_method def self.send(opts = {})
      message = encode(opts)
      data = Meshtastic::Data.new(
        portnum: :ADMIN_APP,
        payload: message.to_proto,
        want_response: opts[:want_response] != false
      )
      Meshtastic.deliver_data(opts.merge(data: data, port_num: Meshtastic::PortNum::ADMIN_APP))
    end

    public_class_method def self.reboot(opts = {})
      send(opts.merge(reboot_seconds: opts[:seconds] || 5))
    end

    public_class_method def self.shutdown(opts = {})
      send(opts.merge(shutdown_seconds: opts[:seconds] || 5))
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
      send(opts.merge(get_channel_request: index))
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
      send(opts.merge(set_canned_message_module_messages: opts[:messages].to_s))
    end

    public_class_method def self.get_device_metadata(opts = {})
      send(opts.merge(get_device_metadata_request: true))
    end

    public_class_method def self.get_ringtone(opts = {})
      send(opts.merge(get_ringtone_request: true))
    end

    public_class_method def self.set_ringtone(opts = {})
      send(opts.merge(set_ringtone_message: opts[:ringtone].to_s))
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
      send(opts.merge(delete_file_request: opts[:path].to_s))
    end

    public_class_method def self.set_scale(opts = {})
      send(opts.merge(set_scale: opts[:scale].to_i))
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
      send(opts.merge(remove_by_nodenum: opts[:node_num].to_i))
    end

    public_class_method def self.set_favorite_node(opts = {})
      send(opts.merge(set_favorite_node: opts[:node_num].to_i))
    end

    public_class_method def self.remove_favorite_node(opts = {})
      send(opts.merge(remove_favorite_node: opts[:node_num].to_i))
    end

    public_class_method def self.set_fixed_position(opts = {})
      position = opts[:position] || Meshtastic::Position.build(lat: opts[:lat], lon: opts[:lon], altitude: opts[:altitude])
      send(opts.merge(set_fixed_position: position))
    end

    public_class_method def self.remove_fixed_position(opts = {})
      send(opts.merge(remove_fixed_position: true))
    end

    public_class_method def self.set_time(opts = {})
      send(opts.merge(set_time_only: opts[:time].to_i))
    end

    public_class_method def self.get_ui_config(opts = {})
      send(opts.merge(get_ui_config_request: true))
    end

    public_class_method def self.store_ui_config(opts = {})
      send(opts.merge(store_ui_config: opts[:ui_config]))
    end

    public_class_method def self.set_ignored_node(opts = {})
      send(opts.merge(set_ignored_node: opts[:node_num].to_i))
    end

    public_class_method def self.remove_ignored_node(opts = {})
      send(opts.merge(remove_ignored_node: opts[:node_num].to_i))
    end

    public_class_method def self.toggle_muted_node(opts = {})
      send(opts.merge(toggle_muted_node: opts[:node_num].to_i))
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
      send(opts.merge(nodedb_reset: true))
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
        # Encode an AdminMessage from matching opts keys.
        #{self}.encode(
          message: 'optional - existing AdminMessage to fill instead of a new one',
          session_passkey: 'optional - bytes from a prior get_*_response to authorize sets'
        )

        # Send an AdminMessage on ADMIN_APP over a connected transport.
        #{self}.send(
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect',
          bluetooth_obj: 'optional - BLE handle from Meshtastic::Bluetooth.connect',
          tcp_obj: 'optional - TCP handle from Meshtastic::TCP.connect',
          mqtt_obj: 'optional - MQTT client from Meshtastic::MQTT.connect',
          want_response: 'optional - request an admin reply (default: true)'
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
          index: 'optional - channel index to request (default: 0)'
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
          messages: 'required - newline-separated canned message text'
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
          serial_obj: 'optional - serial handle from Meshtastic::Serial.connect'
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
