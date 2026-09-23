# frozen_string_literal: true

require 'spec_helper'
require 'meshtastic/payload_formats'

RSpec.describe 'Meshtastic::PayloadFormats' do
  def decode(port, hex)
    Meshtastic::PayloadFormats.decode(portnum: port, payload: [hex.delete(' ')].pack('H*'))
  end

  it 'parses an RFC 791 IPv4 header and preserves the upper-layer bytes' do
    # RFC 791 figure 5, instantiated with documentation-only addresses/data.
    result = decode(33, '45000015006f00007b012b77 0a000001 0a000002 00')
    expect(result).to include(format: :ip, version: 4, header_length: 20, total_length: 21,
                              source: '10.0.0.1', destination: '10.0.0.2', protocol: 1, ttl: 123,
                              identification: 111, header_checksum_valid: true)
    expect(result[:body].bytesize).to eq(1)
    expect(decode(33, '45000029')[:status]).to eq(:malformed)
  end

  it 'parses an RFC 8200 IPv6 base header without inventing extension decoding' do
    result = decode(33, '6000000000033b40 20010db8000000000000000000000001 20010db8000000000000000000000002 010203')
    expect(result).to include(version: 6, source: '2001:db8::1', destination: '2001:db8::2', next_header: 59, hop_limit: 64)
    expect(result[:body].unpack1('H*')).to eq('010203')
  end

  it 'leaves ZPS opaque unless its experimental ESP32 dialect is explicitly selected' do
    # ZPSPlugin::outBufAdd + encodeBSS: uint64 timestamp, reserved word, packed scan.
    bytes = ['0100000000000000 0000000000000000 ffeeddccbbaa063c'.delete(' ')].pack('H*')
    expect(Meshtastic::PayloadFormats.decode(portnum: 68, payload: bytes)[:status]).to eq(:unsupported)
    result = Meshtastic::PayloadFormats.decode(portnum: 68, payload: bytes, zps_profile: :esp32_legacy)
    expect(result).to include(format: :zps, timestamp: 1, profile: :esp32_legacy)
    expect(result[:records]).to eq([{ kind: :wifi, address: 'aa:bb:cc:dd:ee:ff', channel: 6, rssi: -60 }])
  end

  it 'optionally decodes real native Codec2 encoder output to signed PCM through Ruby Fiddle' do
    require 'fiddle'
    begin
      library = Fiddle.dlopen('libcodec2.so')
    rescue Fiddle::DLError
      skip 'optional libcodec2 is not installed'
    end
    create = Fiddle::Function.new(library['codec2_create'], [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP)
    destroy = Fiddle::Function.new(library['codec2_destroy'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
    encode = Fiddle::Function.new(library['codec2_encode'], [Fiddle::TYPE_VOIDP] * 3, Fiddle::TYPE_VOID)
    context = create.call(0)
    frame = "\0".b * 8
    encode.call(context, frame, Array.new(160, 0).pack('s*'))
    destroy.call(context)
    result = Meshtastic::PayloadFormats.decode(portnum: 9, payload: [0xc0, 0xde, 0xc2, 0].pack('C*') + frame, pcm: true)
    expect(result).to include(pcm_decoded: true, pcm_encoding: :s16le, sample_rate: 8000)
    expect(result[:pcm].bytesize).to eq(320)
    expect(result[:frames]).to eq([frame])
  end

  it 'splits firmware Codec2 frames without mistaking compressed bytes for PCM' do
    result = decode(9, 'c0dec200 0011223344556677 8899aabbccddeeff')
    expect(result).to include(format: :codec2, mode: 0, bitrate: 3200, samples_per_frame: 160, pcm_decoded: false)
    expect(result[:frames].map { |frame| frame.unpack1('H*') }).to eq(%w[0011223344556677 8899aabbccddeeff])
    expect(decode(9, 'c0dec20011')[:status]).to eq(:malformed)
    expect(decode(9, 'c0dec2ff')[:status]).to eq(:unsupported)
  end

  it 'decodes ota-common upstream header and start-info test vectors' do
    expect(decode(79, '0307d204c8000004')).to include(format: :ota_common, type: :block, session: 7, index: 1234, offset: 200, total: 1024)
    result = decode(79, '0107000000000000 0004320050c30000c0004000')
    expect(result[:start]).to eq(block_size: 1024, block_count: 50, payload_length: 50_000, manifest_length: 192, signature_length: 64)
    expect(result[:signature_verified]).to be false
  end

  it 'decodes published signed temperature and acceleration examples' do
    expect(decode(:CAYENNE_APP, '0167ffd7')[:records].first[:value]).to eq(-4.1)
    expect(decode(77, '067104d2fb2e0000')[:records].first[:value]).to eq(x: 1.234, y: -1.234, z: 0.0)
  end

  it 'decodes every original Cayenne scalar type and signed GPS coordinates' do
    vectors = { 0 => ['01', 1], 1 => ['00', 0], 2 => ['ff9c', -1], 3 => ['007b', 1.23],
                101 => ['ffff', 65_535], 102 => ['01', 1], 104 => ['64', 50], 115 => ['279d', 1014.1] }
    vectors.each do |type, (value, expected)|
      expect(decode(77, format('01%<type>02x%<value>s', type: type, value: value))[:records].first[:value]).to eq(expected)
    end
    gps = decode(77, '0188 000001 ffffff 000064')[:records].first[:value]
    expect(gps).to eq(latitude: 0.0001, longitude: -0.0001, altitude: 1.0)
    expect(decode(77, '0186 0064 ff9c 0000')[:records].first[:value]).to eq(x: 1, y: -1, z: 0)
  end

  it 'never skips unknown LPP fields or loses malformed wire bytes' do
    result = decode(77, '0167006402feabcd')
    expect(result).to include(status: :unsupported, undecoded_offset: 4)
    expect(result[:records].size).to eq(1)
    expect(result[:remainder].unpack1('H*')).to eq('02feabcd')
    %w[01 0167 016700].each do |hex|
      expect(decode(77, hex)).to include(status: :malformed, raw: [hex].pack('H*'))
    end
    expect(decode(77, '')).to include(status: :decoded, records: [])
  end

  it 'checks IP lengths and keeps options and fragments uninterpreted' do
    result = decode(33, '46000018106f2001800600000a0000010a00000201010000')
    expect(result).to include(header_length: 24, fragment_offset: 8, flags: 1, body: ''.b)
    expect(result[:options].unpack1('H*')).to eq('01010000')
    expect(result[:header_checksum_valid]).to be false
    %w[45000014106f0000800600000a0000010a00000200 44000014106f0000800600000a0000010a000002].each do |hex|
      expect(decode(33, hex)[:status]).to eq(:malformed)
    end
    expect(decode(33, '')[:status]).to eq(:malformed)
    expect(decode(33, 'f0')[:status]).to eq(:unsupported)
    expect(decode(33, '60')[:status]).to eq(:malformed)
  end

  it 'validates all firmware Codec2 mode frame boundaries' do
    [8, 6, 8, 7, 7, 6, 4, 4, 4].each_with_index do |width, mode|
      result = decode(9, format('c0dec2%02x', mode) + ('00' * width))
      expect(result).to include(status: :decoded, bytes_per_frame: width)
      expect(result[:frames].length).to eq(1)
    end
    %w[00 c0dec2 00000000].each { |hex| expect(decode(9, hex)[:status]).to eq(:malformed) }
  end

  it 'decodes OTA load prefixes and controls while bounding fragments' do
    result = decode(79, '0901000000000000 0400000001000000 aabb')
    expect(result[:load]).to eq(total_length: 4, offset: 1, chunk: [0xaa, 0xbb].pack('C*'))
    [5, 6, 7, 8, 10].each do |type|
      expect(decode(79, format('%02x01ffff00000000', type))[:status]).to eq(:decoded)
    end
    expect(decode(79, '0401000000000000')[:status]).to eq(:decoded) # Single-leaf empty proof.
    expect(decode(79, '0201ffff00000400aabb')[:body].unpack1('H*')).to eq('aabb')
    %w[00 0101000000000000 0301000001000100ff 09010000000000000100000001000000ff].each do |hex|
      expect(decode(79, hex)[:status]).to eq(:malformed)
    end
    expect(decode(79, '0b01000000000000')[:status]).to eq(:unsupported)
    expect(decode(79, 'ff01000000000000')[:status]).to eq(:unsupported)
    expect(decode(79, '00' * 234)[:status]).to eq(:malformed)
  end

  it 'decodes the source-defined ZPS position flag and BLE records only in the explicit profile' do
    payload = [0x830000000001, 0xfffffffffffffffe, 0x3cffaabbccddeeff].pack('Q<*')
    result = Meshtastic::PayloadFormats.decode(portnum: 68, payload: payload, zps_profile: :esp32_legacy)
    expect(result[:position]).to eq(latitude_i: -1, longitude_i: -2, pdop: 3)
    expect(result[:records].first).to include(kind: :ble, address: 'aa:bb:cc:dd:ee:ff', rssi: -60)
    result = Meshtastic::PayloadFormats.decode(portnum: 68, payload: 'a', zps_profile: :esp32_legacy)
    expect(result[:status]).to eq(:malformed)
  end

  it 'preserves unknown ports and rejects non-byte inputs' do
    expect(decode(256, 'deadbeef')).to include(format: :opaque, status: :unsupported, raw: ['deadbeef'].pack('H*'))
    expect { Meshtastic::PayloadFormats.decode(portnum: 77, payload: nil) }.to raise_error(ArgumentError)
  end

  it 'documents its public integration options at runtime' do
    expect { Meshtastic::PayloadFormats.help }.to output(/portnum:.*\n.*payload:.*\n.*pcm:.*\n.*zps_profile:/).to_stdout
    expect(Meshtastic::PayloadFormats.authors).not_to be_empty
  end

  it 'decodes the published myDevices two-temperature wire example' do
    result = decode(77, '03 67 01 10 05 67 00 FF')
    expect(result[:format]).to eq(:cayenne_lpp)
    expect(result[:records].map { |r| r.values_at(:channel, :value) }).to eq([[3, 27.2], [5, 25.5]])
  end
end
