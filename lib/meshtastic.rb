# frozen_string_literal: true

require 'meshtastic/version'

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  # Protocol Buffers for Meshtastic
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
  autoload :Mesh, 'meshtastic/mesh'
  autoload :ModuleConfig, 'meshtastic/module_config'
  autoload :MQTT, 'meshtastic/mqtt'
  autoload :Paxcount, 'meshtastic/paxcount'
  autoload :Portnums, 'meshtastic/portnums'
  autoload :RemoteHardware, 'meshtastic/remote_hardware'
  autoload :Rtttl, 'meshtastic/rtttl'
  autoload :Storeforward, 'meshtastic/storeforward'
  autoload :Telemetry, 'meshtastic/telemetry'
  autoload :Xmodem, 'meshtastic/xmodem'

  # Display a List of Every Meshtastic Module

  public_class_method def self.help
    constants.sort
  end
end
