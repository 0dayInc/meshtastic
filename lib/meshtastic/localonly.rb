# frozen_string_literal: true

require 'meshtastic/localonly_pb'

module Meshtastic
  module Localonly
    public_class_method def self.decode_config(opts = {})
      bytes = opts[:bytes]
      Meshtastic::LocalConfig.decode(bytes)
    end

    public_class_method def self.decode_module_config(opts = {})
      bytes = opts[:bytes]
      Meshtastic::LocalModuleConfig.decode(bytes)
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the decode_config class method for this module.
        #{self}.decode_config(
          bytes: 'optional - value for bytes passed into decode_config'
        )

        # Run the decode_module_config class method for this module.
        #{self}.decode_module_config(
          bytes: 'optional - value for bytes passed into decode_module_config'
        )

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
