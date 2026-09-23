# frozen_string_literal: true

require 'ipaddr'

module Meshtastic
  # Stateless binary application decoders; see documentation/payload-formats.md.
  module PayloadFormats
    PORTS = { AUDIO_APP: 9, IP_TUNNEL_APP: 33, ZPS_APP: 68, CAYENNE_APP: 77, LORA_OTA_APP: 79 }.freeze
    LPP_TYPES = {
      0 => [:digital_input, 1, false, 1, nil],
      1 => [:digital_output, 1, false, 1, nil],
      2 => [:analog_input, 2, true, 100, nil],
      3 => [:analog_output, 2, true, 100, nil],
      101 => [:illuminance, 2, false, 1, 'lux'],
      102 => [:presence, 1, false, 1, nil],
      103 => [:temperature, 2, true, 10, 'C'],
      104 => [:relative_humidity, 1, false, 2, '%'],
      113 => [:accelerometer, 6, true, 1000, 'g'],
      115 => [:barometric_pressure, 2, false, 10, 'hPa'],
      134 => [:gyrometer, 6, true, 100, 'degrees/s'],
      136 => [:gps, 9, true, 1, nil]
    }.freeze

    public_class_method def self.decode(opts = {})
      port = opts[:portnum]
      port = PORTS[port.to_sym] if port.is_a?(String) || port.is_a?(Symbol)
      raw = opts[:payload]
      raise ArgumentError, 'payload must be a binary String' unless raw.is_a?(String)

      raw = raw.b
      result = { portnum: port, raw: raw }
      parsed = case port
               when 9 then audio(payload: raw)
               when 33 then ip(payload: raw)
               when 68 then zps(payload: raw, profile: opts[:zps_profile])
               when 77 then cayenne(payload: raw)
               when 79 then ota(payload: raw)
               else { status: :unsupported, format: :opaque, error: 'no verified schema for this port' }
               end
      parsed.merge!(pcm_audio(audio: parsed)) if port == 9 && opts[:pcm] && parsed[:status] == :decoded
      result.merge(parsed)
    rescue ArgumentError => e
      raise unless raw.is_a?(String)

      result.merge(status: :malformed, error: e.message)
    end

    private_class_method def self.cayenne(opts = {})
      raw = opts[:payload]
      records = []
      offset = 0
      while offset < raw.bytesize
        raise ArgumentError, 'truncated Cayenne channel/type' if raw.bytesize - offset < 2

        channel, type = raw.byteslice(offset, 2).unpack('CC')
        definition = LPP_TYPES[type]
        unless definition
          return { format: :cayenne_lpp, status: :unsupported, records: records,
                   error: "unknown Cayenne type #{type}", undecoded_offset: offset, remainder: raw.byteslice(offset..) }
        end
        name, length, signed, divisor, unit = definition
        data = raw.byteslice(offset + 2, length)
        raise ArgumentError, "truncated Cayenne #{name}" unless data && data.bytesize == length

        width = length > 2 ? length / 3 : length
        values = data.bytes.each_slice(width).map do |bytes|
          value = bytes.reduce(0) { |memo, byte| (memo << 8) | byte }
          value -= 1 << (width * 8) if signed && bytes.first >= 128
          value.fdiv(divisor)
        end
        value = if type == 136
                  { latitude: values[0] / 10_000, longitude: values[1] / 10_000, altitude: values[2] / 100 }
                elsif length == 6
                  %i[x y z].zip(values).to_h
                else
                  values.first
                end
        records << { channel: channel, type: type, name: name, value: value, unit: unit }
        offset += length + 2
      end
      { format: :cayenne_lpp, status: :decoded, records: records }
    end

    private_class_method def self.zps(opts = {})
      unless opts[:profile] == :esp32_legacy
        return { format: :opaque, status: :unsupported,
                 error: 'ZPS has no stable port-68 schema; select zps_profile: :esp32_legacy only for that experimental dialect' }
      end
      raw = opts[:payload]
      raise ArgumentError, 'experimental ZPS needs two header words and up to twenty uint64 records' unless (16..176).cover?(raw.bytesize) && (raw.bytesize % 8).zero?

      words = raw.unpack('Q<*')
      header, position = words.shift(2)
      records = words.map do |word|
        channel = (word >> 48) & 255
        { kind: channel == 255 ? :ble : :wifi, address: format('%012x', word & 0xffffffffffff).scan(/../).join(':'),
          channel: channel, rssi: -(word >> 56) }
      end
      result = { format: :zps, status: :decoded, profile: :esp32_legacy, timestamp: header & 0xffffffff,
                 header_word: header, position_word: position, records: records }
      if header.anybits?(0x800000000000)
        longitude, latitude = [position].pack('Q<').unpack('l<2')
        result[:position] = { latitude_i: latitude, longitude_i: longitude, pdop: (header >> 40) & 0x7f }
      end
      result
    end

    private_class_method def self.ip(opts = {})
      raw = opts[:payload]
      raise ArgumentError, 'empty IP packet' if raw.empty?

      version = raw.getbyte(0) >> 4
      result = { format: :ip, status: :decoded, version: version }
      case version
      when 4
        raise ArgumentError, 'truncated IPv4 header' if raw.bytesize < 20

        header_length = (raw.getbyte(0) & 15) * 4
        total_length = raw.byteslice(2, 2).unpack1('n')
        raise ArgumentError, 'invalid IPv4 header/total length' unless header_length.between?(20, total_length) && raw.bytesize == total_length

        flags_offset = raw.byteslice(6, 2).unpack1('n')
        header = raw.byteslice(0, header_length)
        sum = header.unpack('n*').sum
        sum = (sum & 0xffff) + (sum >> 16) while sum > 0xffff
        result.merge(header_length: header_length, total_length: total_length, dscp_ecn: raw.getbyte(1),
                     identification: raw.byteslice(4, 2).unpack1('n'), flags: flags_offset >> 13,
                     fragment_offset: (flags_offset & 0x1fff) * 8, ttl: raw.getbyte(8), protocol: raw.getbyte(9),
                     checksum: raw.byteslice(10, 2).unpack1('n'), header_checksum_valid: sum == 0xffff,
                     source: IPAddr.new_ntoh(raw.byteslice(12, 4)).to_s,
                     destination: IPAddr.new_ntoh(raw.byteslice(16, 4)).to_s,
                     options: raw.byteslice(20, header_length - 20), body: raw.byteslice(header_length..))
      when 6
        raise ArgumentError, 'truncated IPv6 header' if raw.bytesize < 40

        length = raw.byteslice(4, 2).unpack1('n')
        return result.merge(status: :unsupported, error: 'IPv6 jumbogram extension not decoded') if length.zero? && raw.bytesize > 40
        raise ArgumentError, 'invalid IPv6 payload length' unless raw.bytesize == length + 40

        first = raw.unpack1('N')
        result.merge(header_length: 40, payload_length: length, total_length: length + 40,
                     traffic_class: (first >> 20) & 255, flow_label: first & 0xfffff,
                     next_header: raw.getbyte(6), hop_limit: raw.getbyte(7),
                     source: IPAddr.new_ntoh(raw.byteslice(8, 16)).to_s,
                     destination: IPAddr.new_ntoh(raw.byteslice(24, 16)).to_s, body: raw.byteslice(40..))
      else
        result.merge(status: :unsupported, error: 'unknown IP version')
      end
    end

    private_class_method def self.audio(opts = {})
      raw = opts[:payload]
      raise ArgumentError, 'Codec2 needs C0 DE C2 magic and mode byte' unless raw.bytesize >= 4 && raw.byteslice(0, 3) == "\xC0\xDE\xC2".b

      mode = raw.getbyte(3)
      rates = [3200, 2400, 1600, 1400, 1300, 1200, 700, 700, 700]
      bits = [64, 48, 64, 56, 52, 48, 28, 28, 28][mode]
      result = { format: :codec2, mode: mode, pcm_decoded: false, encoded: raw.byteslice(4..) }
      return result.merge(status: :unsupported, error: 'unknown Codec2 mode') unless bits

      width = (bits + 7) / 8
      raise ArgumentError, 'truncated Codec2 frame' unless (result[:encoded].bytesize % width).zero?

      frames = result[:encoded].bytes.each_slice(width).map { |bytes| bytes.pack('C*') }
      result.merge(status: :decoded, bitrate: rates[mode], bits_per_frame: bits, bytes_per_frame: width,
                   samples_per_frame: mode < 2 ? 160 : 320, sample_rate: 8000, frames: frames)
    end

    private_class_method def self.pcm_audio(opts = {})
      require 'fiddle'

      audio = opts[:audio]
      library = Fiddle.dlopen('libcodec2.so')
      pointer = Fiddle::TYPE_VOIDP
      integer = Fiddle::TYPE_INT
      create = Fiddle::Function.new(library['codec2_create'], [integer], pointer)
      destroy = Fiddle::Function.new(library['codec2_destroy'], [pointer], Fiddle::TYPE_VOID)
      samples = Fiddle::Function.new(library['codec2_samples_per_frame'], [pointer], integer)
      bits = Fiddle::Function.new(library['codec2_bits_per_frame'], [pointer], integer)
      decode = Fiddle::Function.new(library['codec2_decode'], [pointer, pointer, pointer], Fiddle::TYPE_VOID)
      context = create.call(audio[:mode])
      return { pcm_decoded: false, pcm_error: 'installed libcodec2 does not support this mode' } if context.null?

      return { pcm_decoded: false, pcm_error: 'native Codec2 geometry differs from wire profile' } unless samples.call(context) == audio[:samples_per_frame] && bits.call(context) == audio[:bits_per_frame]

      pcm = audio[:frames].map do |frame|
        buffer = "\0".b * (audio[:samples_per_frame] * 2)
        decode.call(context, buffer, frame)
        buffer.unpack('s*').pack('s<*')
      end.join.b
      { pcm_decoded: true, pcm_encoding: :s16le, pcm: pcm }
    rescue LoadError, StandardError => e
      # Optional native decoding must never discard already decoded framing.
      { pcm_decoded: false, pcm_error: e.message }
    ensure
      destroy.call(context) if context && !context.null?
    end

    private_class_method def self.ota(opts = {})
      raw = opts[:payload]
      raise ArgumentError, 'OTA frame must contain 8..233 bytes' unless (8..233).cover?(raw.bytesize)

      type, session, index, offset, total = raw.unpack('CCv3')
      names = %i[unknown start manifest block proof request ack done abort load load_commit announce]
      body = raw.byteslice(8..)
      result = { format: :ota_common, status: :decoded, type: names[type] || :unknown,
                 type_id: type, session: session, index: index, offset: offset, total: total,
                 body: body, signature_verified: false }
      case type
      when 1
        raise ArgumentError, 'OTA START needs 12 bytes' unless body.bytesize == 12

        result[:start] = %i[block_size block_count payload_length manifest_length signature_length].zip(body.unpack('vvVvv')).to_h
      when 2, 3, 4
        raise ArgumentError, 'OTA fragment exceeds logical unit' if offset + body.bytesize > total
      when 5, 6, 7, 8, 10
        raise ArgumentError, 'OTA control frame has unexpected body' unless body.empty?
      when 9
        raise ArgumentError, 'OTA LOAD needs 8-byte prefix' if body.bytesize < 8

        length, position = body.unpack('V2')
        chunk = body.byteslice(8..)
        raise ArgumentError, 'OTA LOAD chunk exceeds package' if position + chunk.bytesize > length

        result[:load] = { total_length: length, offset: position, chunk: chunk }
      else
        result.merge!(status: :unsupported, error: 'OTA body schema not established for this frame type')
      end
      result
    end

    public_class_method def self.authors
      'Meshtastic Ruby contributors'
    end

    public_class_method def self.help
      puts "# Decode a binary application payload without modifying its bytes.
#{self}.decode(
  portnum: 'required - numeric or named Meshtastic application port',
  payload: 'required - raw binary application payload String',
  pcm: 'optional - decode Codec2 to s16le audio using installed libcodec2; default false',
  zps_profile: 'optional - select :esp32_legacy for the experimental little-endian ZPS dialect'
)
# Identify the module authors.
#{self}.authors"
    end
  end
end
