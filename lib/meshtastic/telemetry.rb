# frozen_string_literal: true

require 'meshtastic/telemetry_pb'

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  module Telemetry
    # Author(s):: 0day Inc. <support@0dayinc.com>

    public_class_method def self.authors
      "AUTHOR(S):
        0day Inc. <support@0dayinc.com>
      "
    end

    # Display Usage for this Module

    public_class_method def self.help
      puts "USAGE:
        #{self}.authors
      "
    end
  end
end
