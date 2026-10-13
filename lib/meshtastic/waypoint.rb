# frozen_string_literal: true

require 'meshtastic/mesh_pb'

module Meshtastic
  class Waypoint
    public_class_method def self.build(opts = {})
      fields = opts.fetch(:fields, {})
      raise ArgumentError, 'fields must be a Waypoint field Hash' unless fields.is_a?(Hash)
      raise ArgumentError, 'nil fields are not valid waypoint values' if fields.values.any?(&:nil?)

      box = fields[:bounding_box] || fields['bounding_box']
      raise ArgumentError, 'bounding_box coordinates cannot be nil' if box.is_a?(Hash) && box.values.any?(&:nil?)

      waypoint = new(fields)
      raise ArgumentError, 'latitude_i and longitude_i must be supplied together' if !waypoint.has_latitude_i? != !waypoint.has_longitude_i?
      raise ArgumentError, 'a circular geofence requires latitude_i and longitude_i' if waypoint.geofence_radius.positive? && !waypoint.has_latitude_i?

      validate_coordinates(fields: { latitude_i: waypoint.latitude_i, longitude_i: waypoint.longitude_i })
      if waypoint.bounding_box
        box = waypoint.bounding_box
        validate_coordinates(fields: { latitude_south_i: box.latitude_south_i, latitude_north_i: box.latitude_north_i,
                                       longitude_west_i: box.longitude_west_i, longitude_east_i: box.longitude_east_i })
        raise ArgumentError, 'bounding_box requires south <= north and west <= east; split antimeridian regions' unless box.latitude_south_i <= box.latitude_north_i && box.longitude_west_i <= box.longitude_east_i
      end
      { name: 29, description: 99 }.each do |field, maximum|
        text = waypoint.public_send(field)
        raise ArgumentError, "#{field} must be valid NUL-free UTF-8 and at most #{maximum} bytes" unless text.valid_encoding? && !text.include?("\0") && text.bytesize <= maximum
      end
      waypoint
    rescue TypeError, RangeError, EncodingError => e
      raise ArgumentError, e.message
    end

    private_class_method def self.validate_coordinates(opts = {})
      opts.fetch(:fields).each do |field, value|
        maximum = field.to_s.start_with?('latitude') ? 900_000_000 : 1_800_000_000
        raise ArgumentError, "#{field} is outside geographic bounds" unless value.is_a?(Integer) && value.between?(-maximum, maximum)
      end
    end

    public_class_method def self.transmit(opts = {})
      waypoint = opts[:waypoint]
      raise ArgumentError, 'waypoint must be a Waypoint protobuf' if waypoint && !waypoint.is_a?(self)
      raise ArgumentError, 'supply waypoint or fields, not both' if waypoint && opts.key?(:fields)

      waypoint = build(fields: waypoint ? waypoint.to_h : opts.fetch(:fields, {}))
      data = Meshtastic::Data.new(portnum: :WAYPOINT_APP, payload: waypoint.to_proto)
      Meshtastic.deliver_data(opts.except(:waypoint, :fields).merge(data: data, port_num: Meshtastic::PortNum::WAYPOINT_APP))
    end

    public_class_method def self.authors
      "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n      "
    end

    public_class_method def self.help
      puts "USAGE:
        # Build a waypoint or geofence protobuf.
        #{self}.build(fields: 'optional - exact Waypoint field hash; coordinates are integer degrees times 10000000; default empty message')
        # fields: latitude_i and longitude_i must be paired, within +/-90 and +/-180 degrees scaled by 10000000.
        # geofence_radius is uint32 meters, positive requires center; zero means no circle.
        # bounding_box uses longitude_west_i, latitude_south_i, longitude_east_i, latitude_north_i.
        # Require west <= east and south <= north; circle and box can coexist.
        # notify_on_enter, notify_on_exit and notify_favorites_only are booleans resolved on receivers.
        # name and description allow 29 and 99 UTF-8 bytes respectively, without embedded NUL.
        # id, expire, locked_to and icon retain the exact protobuf integer semantics.
        # Send a validated waypoint over WAYPOINT_APP.
        #{self}.transmit(
          waypoint: 'optional - Waypoint protobuf to validate and transmit instead of fields',
          fields: 'optional - exact Waypoint fields as accepted by build; default empty message',
          serial_obj: 'optional - connected serial handle; choose exactly one transport',
          bluetooth_obj: 'optional - connected Bluetooth handle',
          tcp_obj: 'optional - connected TCP handle',
          mqtt_obj: 'optional - connected MQTT client; accepts channel_id and psks',
          to: 'optional - destination !eighthex node ID; defaults to broadcast',
          want_ack: 'optional - request routing acknowledgment, not proof of delivery',
          pki_encrypted: 'optional - radio-owned PKI encryption; MQTT PKI unsupported',
          public_key: 'optional - recipient public-key bytes for radio PKI'
        )
        # Print the module author information.
        #{self}.authors
      "
    end
  end
end
