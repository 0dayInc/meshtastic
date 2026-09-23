# frozen_string_literal: true

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  require 'base64'
  # Protocol Buffers for Meshtastic
  require 'meshtastic/admin_pb'
  require 'meshtastic/apponly_pb'
  require 'meshtastic/atak_pb'
  require 'meshtastic/cannedmessages_pb'
  require 'meshtastic/channel_pb'
  require 'meshtastic/clientonly_pb'
  require 'meshtastic/config_pb'
  require 'meshtastic/connection_status_pb'
  require 'meshtastic/deviceonly_legacy_pb'
  require 'meshtastic/deviceonly_pb'
  require 'meshtastic/device_ui_pb'
  require 'meshtastic/interdevice_pb'
  require 'meshtastic/localonly_pb'
  require 'meshtastic/lorawan_bridge_pb'
  require 'meshtastic/mesh_beacon_pb'
  require 'meshtastic/mesh_pb'
  require 'meshtastic/module_config_pb'
  require 'meshtastic/mqtt_pb'
  require 'meshtastic/paxcount_pb'
  require 'meshtastic/portnums_pb'
  require 'meshtastic/powermon_pb'
  require 'meshtastic/remote_hardware_pb'
  require 'meshtastic/rtttl_pb'
  require 'meshtastic/serial_hal_pb'
  require 'meshtastic/storeforward_pb'
  require 'meshtastic/telemetry_pb'
  require 'meshtastic/version'
  require 'meshtastic/xmodem_pb'

  require 'nanopb_pb'
  require 'openssl'

  autoload :Admin, 'meshtastic/admin'
  autoload :Apponly, 'meshtastic/apponly'
  autoload :ATAK, 'meshtastic/atak'
  autoload :Bluetooth, 'meshtastic/bluetooth'
  autoload :Cannedmessages, 'meshtastic/cannedmessages'
  autoload :Clientonly, 'meshtastic/clientonly'
  autoload :ConnectionStatus, 'meshtastic/connection_status'
  autoload :Deviceonly, 'meshtastic/deviceonly'
  autoload :Forwarder, 'meshtastic/forwarder'
  autoload :Localonly, 'meshtastic/localonly'
  autoload :MeshInterface, 'meshtastic/mesh_interface'
  autoload :MQTT, 'meshtastic/mqtt'
  autoload :Portnums, 'meshtastic/portnums'
  autoload :PayloadFormats, 'meshtastic/payload_formats'
  autoload :RemoteHardware, 'meshtastic/remote_hardware'
  autoload :RTTTL, 'meshtastic/rtttl'
  autoload :Serial, 'meshtastic/serial'
  autoload :Storeforward, 'meshtastic/storeforward'
  autoload :StreamInterface, 'meshtastic/stream_interface'
  autoload :TCP, 'meshtastic/tcp'
  autoload :Traceroute, 'meshtastic/traceroute'
  autoload :Util, 'meshtastic/util'
  autoload :Unishox2, 'meshtastic/unishox2'
  autoload :Xmodem, 'meshtastic/xmodem'

  # Constants
  NODELESS_WANT_CONFIG_ID = 69_420
  START1 = 0x94
  START2 = 0xC3
  HEADER_LEN = 4
  MAX_TO_FROM_RADIO_SIZE = 512

  # Display a List of Every Meshtastic Module

  public_class_method def self.authors
    "AUTHOR(S):\n      0day Inc. <support@0dayinc.com>\n    "
  end

  public_class_method def self.help
    puts "        USAGE:
        # Run the deliver_data class method for this module.
        #{self}.deliver_data(
          data: 'optional - value for data passed into deliver_data',
          serial_obj: 'optional - value for serial_obj passed into deliver_data',
          bluetooth_obj: 'optional - value for bluetooth_obj passed into deliver_data',
          tcp_obj: 'optional - value for tcp_obj passed into deliver_data',
          mqtt_obj: 'optional - value for mqtt_obj passed into deliver_data'
        )

        # Run the authors class method for this module.
        #{self}.authors

    "
  end

  public_class_method def self.deliver_data(opts = {})
    raise ArgumentError, 'data is required' unless opts[:data].is_a?(Meshtastic::Data)

    if opts[:serial_obj]
      Serial.send_data(opts)
    elsif opts[:bluetooth_obj]
      Bluetooth.send_data(opts)
    elsif opts[:tcp_obj]
      TCP.send_data(opts)
    elsif opts[:mqtt_obj]
      MQTT.send_data(opts)
    else
      raise ArgumentError, 'serial_obj, bluetooth_obj, tcp_obj, or mqtt_obj is required'
    end
  end
end

require 'meshtastic/channel'
require 'meshtastic/config'
require 'meshtastic/module_config'
require 'meshtastic/paxcount'
require 'meshtastic/position'
require 'meshtastic/reticulum'
require 'meshtastic/telemetry'
