# frozen_string_literal: true

module Meshtastic
  # Framing for landandair/RNS_Over_Meshtastic, not an RNS plaintext decoder.
  module Reticulum
    public_class_method def self.decode_chunks(opts = {})
      chunks = opts[:chunks]
      limit = opts.fetch(:max_bytes, 564)
      raise ArgumentError, 'Reticulum byte limit must be 1..564' unless limit.is_a?(Integer) && (1..564).cover?(limit)
      raise ArgumentError, 'Reticulum requires 1..128 grouped chunks' unless chunks.is_a?(Array) && (1..128).cover?(chunks.length)

      fragments = chunks.map { |payload| decode_packet(payload: payload) }.sort_by { |frame| frame[:index] }
      raise ArgumentError, 'Reticulum control cannot be reassembled' unless fragments.all? { |frame| frame[:format] == :reticulum_fragment }
      raise ArgumentError, 'Reticulum mixed message indexes' unless fragments.map { |frame| frame[:message_index] }.uniq.length == 1
      raise ArgumentError, 'Reticulum duplicate or conflicting position' unless fragments.map { |frame| frame[:index] }.uniq.length == fragments.length

      finals = fragments.select { |frame| frame[:final] }
      raise ArgumentError, 'Reticulum missing or conflicting final count' unless finals.length == 1

      count = finals.first[:count]
      raise ArgumentError, 'Reticulum missing or out-of-range fragments' unless fragments.map { |frame| frame[:index] } == (1..count).to_a
      raise ArgumentError, 'Reticulum reassembly exceeds byte limit' if fragments.sum { |frame| frame[:body].bytesize } > limit

      { format: :reticulum_packet, complete: true, message_index: fragments.first[:message_index],
        count: fragments.last[:count], body: fragments.map { |frame| frame[:body] }.join.b,
        raw_chunks: fragments.map { |frame| frame[:raw] }, fragments: fragments }
    end

    public_class_method def self.authors
      '0day Inc.; tunnel protocol: landandair/RNS_Over_Meshtastic'
    end

    public_class_method def self.help
      puts "USAGE:
        # Decode one port 76 tunnel frame without inner RNS interpretation.
        #{self}.decode_packet(
          payload: 'required - binary String including the two-byte header or REQ prefix'
        )
        # Reassemble an explicitly isolated complete message without persistent state.
        #{self}.decode_chunks(
          chunks: 'required - array of wire Strings from one sender/channel/connection/message generation',
          max_bytes: 'optional - aggregate body byte ceiling, integer 1..564, default 564'
        )
        # List authors and protocol attribution.
        #{self}.authors
      "
    end

    public_class_method def self.decode_packet(opts = {})
      payload = opts[:payload]
      raise ArgumentError, 'Reticulum payload must be a binary String' unless payload.is_a?(String)
      raise ArgumentError, 'Reticulum wire length must be 3..202 bytes' unless (3..202).cover?(payload.bytesize)

      bytes = payload.b
      request = bytes.start_with?('REQ')
      raise ArgumentError, 'Reticulum REQ must contain exactly five bytes' if request && bytes.bytesize != 5

      message_index, position = bytes.byteslice(request ? 3 : 0, 2).unpack('Cc')
      raise ArgumentError, 'Reticulum position must not be zero' if position.zero?

      if request
        return { format: :reticulum_request, message_index: message_index, position: position,
                 index: position.abs, raw: bytes, complete: false }
      end
      { format: :reticulum_fragment, message_index: message_index, position: position,
        index: position.abs, count: position.negative? ? -position : nil,
        final: position.negative?, complete: position == -1,
        raw: bytes, body: bytes.byteslice(2..) }
    end
  end
end
