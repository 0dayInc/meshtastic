# frozen_string_literal: true

require 'meshtastic/forwarder_pb'
require 'zlib'
require 'stringio'
require 'time'

module Meshtastic
  # libcotshrink protobuf decoding. Detail is a schema-level hash, not CoT XML.
  module Forwarder
    MAX_BYTES = 1_048_576
    class UnsupportedFormat < ArgumentError
    end
    SOURCES = %w[DTED0 DTED1 DTED2 DTED3 LIDAR PFI USER ??? GPS SRTM1 COT PRI CALC ESTIMATED RTK DGPS GPS_PPS].freeze
    EXTENSIONS = [
      [:how, 3, %w[h-e h-g-i-g-o m-g]],
      [:geopointsrc, 6, SOURCES], [:altsrc, 6, SOURCES],
      [:role, 5, ['Team Member', 'Team Lead', 'HQ', 'Sniper', 'Medic', 'Forward Observer', 'RTO', 'K9']],
      [:battery, 8, nil], [:readiness, 2, :boolean], [:labels_on, 2, :boolean],
      [:height_unit, 4, nil], [:ce_human_input, 2, :boolean], [:tog, 2, :boolean],
      [:route_planning_method, 2, %w[Infil Exfil]],
      [:route_method, 4, %w[Driving Walking Flying Swimming Watercraft]],
      [:route_type, 2, ['On Foot', 'Vehicle']], [:route_route_type, 2, %w[Primary Secondary]],
      [:route_order, 2, ['Ascending Check Points', 'Descending Check Points']], [:route_stroke, 8, nil]
    ].freeze

    public_class_method def self.decode(opts = {})
      bytes = opts[:payload].to_s.b
      limit = byte_limit(opts)
      raise ArgumentError, 'Forwarder input exceeds byte limit' if bytes.bytesize > limit

      compression = bytes.start_with?("\x1f\x8b".b) ? :gzip : :none
      bytes = gunzip(payload: bytes, max_bytes: limit) if compression == :gzip
      raise UnsupportedFormat, 'libcotshrink EXI requires a schema-less EXI grammar decoder; not implemented in Ruby' if bytes.start_with?('$EXI') || (bytes.getbyte(0) && (bytes.getbyte(0) & 0xC0) == 0x80)

      message = ForwarderProtobuf::CotEvent.decode(bytes)
      extensions = unpack_extensions(value: message.customBytesExt)
      event = unpack_event(message: message, start_of_year: opts[:start_of_year])
      event[:how] = extensions[:how]
      {
        format: :libcotshrink_protobuf, compression: compression,
        protobuf: message.to_h, event: event, extensions: extensions
      }
    rescue Google::Protobuf::ParseError => e
      raise ArgumentError, "invalid libcotshrink protobuf: #{e.message}"
    end

    # Packet payload includes the upstream (index << 4 | count) byte.
    public_class_method def self.decode_packet(opts = {})
      fragment = parse_fragment(opts.merge({}))
      return fragment unless fragment[:count] == 1

      decode_body(opts.merge(payload: fragment[:body]))
    end

    # Stateless reassembly: callers group only chunks known to belong together.
    public_class_method def self.decode_chunks(opts = {})
      chunks = opts[:chunks]
      raise ArgumentError, 'Forwarder requires one to fifteen chunks' unless chunks.is_a?(Array) && (1..15).cover?(chunks.length)

      fragments = chunks.map { |payload| parse_fragment(payload: payload) }
      count = fragments.first[:count]
      raise ArgumentError, 'inconsistent Forwarder chunk counts' unless fragments.all? { |fragment| fragment[:count] == count }
      raise ArgumentError, 'duplicate Forwarder chunk index' unless fragments.map { |fragment| fragment[:index] }.uniq.length == fragments.length
      raise ArgumentError, 'missing Forwarder chunks' unless fragments.length == count
      raise ArgumentError, 'Forwarder reassembly exceeds byte limit' if fragments.sum { |fragment| fragment[:body].bytesize } > byte_limit(opts)

      bytes = fragments.sort_by { |fragment| fragment[:index] }.map { |fragment| fragment[:body] }.join.b
      decode_body(opts.merge(payload: bytes))
    end

    public_class_method def self.authors
      '0day Inc.; libcotshrink schema and format: paulmandal (MIT)'
    end

    public_class_method def self.help
      puts "USAGE:
        # Decode reassembled libcotshrink event bytes.
        #{self}.decode(
          payload: 'required - reassembled protobuf or GZIP bytes without chunk header',
          max_bytes: 'optional - input and decompressed byte ceiling up to 1048576',
          start_of_year: 'optional - explicit Time epoch matching sender year and timezone; otherwise return offsets'
        )
        # Decode one header-bearing port 257 packet.
        #{self}.decode_packet(
          payload: 'required - one complete Meshtastic Forwarder port payload',
          max_bytes: 'optional - maximum input and decompressed bytes',
          start_of_year: 'optional - explicit Time epoch for sender timestamps'
        )
        # Reassemble an explicitly grouped complete message.
        #{self}.decode_chunks(
          chunks: 'required - array of header-bearing packets from one message and sender',
          max_bytes: 'optional - maximum reassembled and decompressed bytes',
          start_of_year: 'optional - explicit Time epoch for sender timestamps'
        )
        # List decoder authors and upstream attribution.
        #{self}.authors
      "
    end

    private_class_method def self.byte_limit(opts = {})
      limit = opts[:max_bytes] || MAX_BYTES
      raise ArgumentError, 'invalid Forwarder byte limit' unless limit.is_a?(Integer) && limit.positive? && limit <= MAX_BYTES

      limit
    end

    private_class_method def self.parse_fragment(opts = {})
      bytes = opts[:payload].to_s.b
      limit = byte_limit(opts)
      raise ArgumentError, 'Forwarder chunk exceeds byte limit' if bytes.bytesize > limit
      raise ArgumentError, 'missing Forwarder chunk header' if bytes.empty?

      index = bytes.getbyte(0) >> 4
      count = bytes.getbyte(0) & 15
      raise ArgumentError, 'invalid Forwarder chunk header' unless count.positive? && index < count

      { format: :forwarder_fragment, index: index, count: count, body: bytes.byteslice(1..) }
    end

    private_class_method def self.decode_body(opts = {})
      bytes = opts[:payload]
      return decode(opts) unless bytes.start_with?('ATAKBCAST,')

      fields = bytes.dup.force_encoding(Encoding::UTF_8)
      raise ArgumentError, 'invalid Forwarder discovery UTF-8' unless fields.valid_encoding?

      fields = fields.split(',', -1)
      raise ArgumentError, 'invalid Forwarder discovery fields' unless fields.length == 5 && %w[0 1].include?(fields[4])

      { format: :forwarder_discovery, mesh_id: fields[1], uid: fields[2], callsign: fields[3], initial: fields[4] == '1' }
    end

    private_class_method def self.gunzip(opts = {})
      reader = Zlib::GzipReader.new(StringIO.new(opts[:payload]))
      output = reader.read(opts[:max_bytes] + 1)
      raise ArgumentError, 'Forwarder GZIP output exceeds byte limit' if output.bytesize > opts[:max_bytes]
      raise ArgumentError, 'Forwarder GZIP trailing bytes are unsupported' if reader.unused && !reader.unused.empty?

      output
    rescue Zlib::Error, EOFError => e
      raise ArgumentError, "invalid Forwarder GZIP: #{e.message}"
    ensure
      reader&.close
    end

    private_class_method def self.unpack_event(opts = {})
      message = opts[:message]
      packed = message.customBytes
      offset = packed >> 39
      stale = (packed >> 16) & 0x7FFFFF
      hae = ((packed & 0xFFFF) / 3.0) - 900
      hae = 9_999_999 if hae == 20_945
      event = {
        uid: message.uid, type: message.type.empty? ? 'a-f-G-U-C' : message.type,
        lat: message.lat / 10_000_000.0, lon: message.lon / 10_000_000.0,
        ce: message.ce, le: message.le, hae: hae,
        time_offset_seconds: offset, stale_after_seconds: stale
      }
      epoch = opts[:start_of_year]
      if epoch
        raise ArgumentError, 'start_of_year must be a Time' unless epoch.is_a?(Time)

        event[:time] = (epoch + offset).utc.iso8601
        event[:start] = event[:time]
        event[:stale] = (epoch + offset + stale).utc.iso8601
      end
      event
    end

    private_class_method def self.unpack_extensions(opts = {})
      shift = 64
      EXTENSIONS.to_h do |name, width, mapping|
        shift -= width
        value = (opts[:value] >> shift) & ((1 << width) - 1)
        nullable = name != :how
        decoded = if nullable && value[width - 1] == 1
                    nil
                  elsif mapping == :boolean
                    value == 1
                  elsif mapping
                    mapping.fetch(value) { raise ArgumentError, "invalid libcotshrink #{name} mapping" }
                  else
                    value
                  end
        [name, decoded]
      end
    end
  end
end
