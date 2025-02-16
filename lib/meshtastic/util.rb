# frozen_string_literal: true

require 'meshtastic/xmodem_pb'

# Plugin used to interact with Meshtastic nodes
module Meshtastic
  module Util
    class Acknowledgement
      attr_accessor :received_ack,
                    :received_nak,
                    :received_impl_ack,
                    :received_trace_route,
                    :received_telemetry,
                    :received_position,
                    :received_waypoint

      def initialize
        @received_ack = false
        @received_nak = false
        @received_impl_ack = false
        @received_trace_route = false
        @received_telemetry = false
        @received_position = false
        @received_waypoint = false
      end

      def reset
        @received_ack = false
        @received_nak = false
        @received_impl_ack = false
        @received_trace_route = false
        @received_telemetry = false
        @received_position = false
        @received_waypoint = false
      end
    end

    class Timeout
      attr_accessor :expire_timeout,
                    :expire_time,
                    :sleep_interval

      def initialize(opts = {})
        @expire_timeout = opts[:expire_timeout] || 20
        @expire_time = 0
        @sleep_interval = 0.1
      end

      def reset
        @expire_time = Time.now.to_i + @expire_timeout
      end
    end

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
