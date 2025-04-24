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
  require 'meshtastic/deviceonly_pb'
  require 'meshtastic/device_ui_pb'
  require 'meshtastic/interdevice_pb'
  require 'meshtastic/localonly_pb'
  require 'meshtastic/mesh_pb'
  require 'meshtastic/module_config_pb'
  require 'meshtastic/mqtt_pb'
  require 'meshtastic/paxcount_pb'
  require 'meshtastic/portnums_pb'
  require 'meshtastic/powermon_pb'
  require 'meshtastic/remote_hardware_pb'
  require 'meshtastic/rtttl_pb'
  require 'meshtastic/storeforward_pb'
  require 'meshtastic/telemetry_pb'
  require 'meshtastic/version'
  require 'meshtastic/xmodem_pb'

  require 'nanopb_pb'
  require 'openssl'

  autoload :Admin, 'meshtastic/admin'
  autoload :Apponly, 'meshtastic/apponly'
  autoload :ATAK, 'meshtastic/atak'
  autoload :Cannedmessages, 'meshtastic/cannedmessages'
  autoload :Channel, 'meshtastic/channel'
  autoload :Clientonly, 'meshtastic/clientonly'
  autoload :Config, 'meshtastic/config'
  autoload :ConnectionStatus, 'meshtastic/connection_status'
  autoload :Deviceonly, 'meshtastic/deviceonly'
  autoload :Localonly, 'meshtastic/localonly'
  autoload :MeshInterface, 'meshtastic/mesh_interface'
  autoload :ModuleConfig, 'meshtastic/module_config'
  autoload :MQTT, 'meshtastic/mqtt'
  autoload :Paxcount, 'meshtastic/paxcount'
  autoload :Portnums, 'meshtastic/portnums'
  autoload :RemoteHardware, 'meshtastic/remote_hardware'
  autoload :RTTTL, 'meshtastic/rtttl'
  autoload :SerialInterface, 'meshtastic/serial_interface'
  autoload :Storeforward, 'meshtastic/storeforward'
  autoload :StreamInterface, 'meshtastic/stream_interface'
  autoload :Telemetry, 'meshtastic/telemetry'
  autoload :Util, 'meshtastic/util'
  autoload :Xmodem, 'meshtastic/xmodem'

  # Constants
  NODELESS_WANT_CONFIG_ID = 69_420
  START1 = 0x94
  START2 = 0xC3
  HEADER_LEN = 4
  MAX_TO_FROM_RADIO_SIZE = 512

  # Display a List of Every Meshtastic Module

  public_class_method def self.help
    constants.sort
  end
end
