# frozen_string_literal: true

require 'meshtastic/portnums_pb'

module Meshtastic
  module Portnums
    public_class_method def self.lookup(opts = {})
      name_or_number = opts[:value] || opts[:name_or_number]
      if name_or_number.is_a?(Integer)
        Meshtastic::PortNum.lookup(name_or_number)
      else
        Meshtastic::PortNum.resolve(name_or_number.to_sym)
      end
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "        USAGE:
        # Run the lookup class method for this module.
        #{self}.lookup(
          value: 'optional - value for value passed into lookup',
          name_or_number: 'optional - value for name_or_number passed into lookup'
        )

        # Run the authors class method for this module.
        #{self}.authors

      "
    end
  end
end
