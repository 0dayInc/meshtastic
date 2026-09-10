# frozen_string_literal: true

require 'meshtastic/localonly_pb'

module Meshtastic
  module Localonly
    def self.decode_config(bytes)
      Meshtastic::LocalConfig.decode(bytes)
    end

    def self.decode_module_config(bytes)
      Meshtastic::LocalModuleConfig.decode(bytes)
    end

    def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    def self.help
      puts "USAGE:
        #{self}.decode_config(bytes)
        #{self}.decode_module_config(bytes)
        #{self}.authors
      "
    end
  end
end
