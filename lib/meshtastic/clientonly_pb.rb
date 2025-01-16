# Generated by the protocol buffer compiler.  DO NOT EDIT!
# source: meshtastic/clientonly.proto

require 'google/protobuf'

require 'meshtastic/localonly_pb'
require 'meshtastic/mesh_pb'

Google::Protobuf::DescriptorPool.generated_pool.build do
  add_file("meshtastic/clientonly.proto", :syntax => :proto3) do
    add_message "meshtastic.DeviceProfile" do
      proto3_optional :long_name, :string, 1
      proto3_optional :short_name, :string, 2
      proto3_optional :channel_url, :string, 3
      proto3_optional :config, :message, 4, "meshtastic.LocalConfig"
      proto3_optional :module_config, :message, 5, "meshtastic.LocalModuleConfig"
      proto3_optional :fixed_position, :message, 6, "meshtastic.Position"
      proto3_optional :ringtone, :string, 7
      proto3_optional :canned_messages, :string, 8
    end
  end
end

module Meshtastic
  DeviceProfile = ::Google::Protobuf::DescriptorPool.generated_pool.lookup("meshtastic.DeviceProfile").msgclass
end
