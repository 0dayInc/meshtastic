# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'digest'

describe Meshtastic::Admin::Firmware do
  def fake_serial_obj
    written = +''.b
    serial_conn = Object.new
    serial_conn.define_singleton_method(:write) do |b|
      written << b
      b.bytesize
    end
    serial_conn.define_singleton_method(:flush) { true }
    serial_conn.define_singleton_method(:closed?) { false }
    serial_conn.define_singleton_method(:close) { true }
    { serial_conn: serial_conn, written: written, my_node_num: 0xb0b }
  end

  def decode_frames(serial_obj)
    buf = serial_obj[:written].dup
    frames = []
    until buf.bytesize < 4
      break unless buf.getbyte(0) == Meshtastic::START1 && buf.getbyte(1) == Meshtastic::START2

      len = (buf.getbyte(2) << 8) + buf.getbyte(3)
      break if buf.bytesize < 4 + len

      frames << Meshtastic::ToRadio.decode(buf.byteslice(4, len))
      buf = buf.byteslice((4 + len)..)
    end
    frames
  end

  def firmware_file(bytes = "hello firmware\n")
    file = Tempfile.new(['fw', '.bin'])
    file.binmode
    file.write(bytes)
    file.flush
    file
  end

  it 'sends ota_request with SHA-256 and BLE mode' do
    serial_obj = fake_serial_obj
    file = firmware_file('abc')
    described_class.request_ota(serial_obj: serial_obj, firmware: file.path, mode: :OTA_BLE)
    packet = decode_frames(serial_obj).last.packet
    admin = Meshtastic::AdminMessage.decode(packet.decoded.payload)
    expect(packet.decoded.portnum).to eq(:ADMIN_APP)
    expect(admin.ota_request.reboot_ota_mode).to eq(:OTA_BLE)
    expect(admin.ota_request.ota_hash.bytesize).to eq(32)
    expect(admin.ota_request.ota_hash).to eq(Digest::SHA256.digest('abc'))
  ensure
    file.close!
  end

  it 'sends enter_dfu_mode_request' do
    serial_obj = fake_serial_obj
    described_class.enter_dfu(serial_obj: serial_obj)
    admin = Meshtastic::AdminMessage.decode(decode_frames(serial_obj).last.packet.decoded.payload)
    expect(admin.enter_dfu_mode_request).to be true
  end

  it 'builds XModem SOH blocks with CRC16 and an EOT' do
    blocks = described_class.xmodem_blocks(bytes: 'A' * 130)
    expect(blocks.first.control).to eq(:SOH)
    expect(blocks.first.seq).to eq(1)
    expect(blocks.first.buffer.bytesize).to eq(128)
    expect(blocks[1].seq).to eq(2)
    expect(blocks.last.control).to eq(:EOT)
  end

  it 'streams XModem ToRadio frames after ota_request on serial' do
    serial_obj = fake_serial_obj
    file = firmware_file('A' * 10)
    described_class.install(serial_obj: serial_obj, firmware: file.path, mode: :OTA_BLE)
    frames = decode_frames(serial_obj)
    admin = Meshtastic::AdminMessage.decode(frames.first.packet.decoded.payload)
    expect(admin.ota_request.ota_hash.bytesize).to eq(32)
    xmodem = frames[1..]
    expect(xmodem.first.xmodemPacket.control).to eq(:SOH)
    expect(xmodem.last.xmodemPacket.control).to eq(:EOT)
  ensure
    file.close!
  end

  it 'publishes ota_request over MQTT without XModem PhoneAPI frames' do
    published = []
    mqtt_obj = Object.new
    mqtt_obj.define_singleton_method(:client_id) { '00000b0b' }
    mqtt_obj.define_singleton_method(:publish) do |topic, payload|
      published << { topic: topic, payload: payload }
      payload.bytesize
    end
    file = firmware_file('xyz')
    described_class.install(mqtt_obj: mqtt_obj, firmware: file.path, mode: :OTA_WIFI, to: '!aabbccdd')
    expect(published.size).to eq(1)
    envelope = Meshtastic::ServiceEnvelope.decode(published.first[:payload])
    packet = envelope.packet
    nonce = [packet.id].pack('V').ljust(8, "\x00") + [packet.from].pack('V').ljust(8, "\x00")
    psk = Base64.strict_decode64('1PG7OiApB1nwvP+rz05pAQ==')
    cipher = OpenSSL::Cipher.new('AES-128-CTR')
    cipher.decrypt
    cipher.key = psk
    cipher.iv = nonce
    data = Meshtastic::Data.decode(cipher.update(packet.encrypted) + cipher.final)
    expect(data.portnum).to eq(:ADMIN_APP)
    admin = Meshtastic::AdminMessage.decode(data.payload)
    expect(admin.ota_request.reboot_ota_mode).to eq(:OTA_WIFI)
  ensure
    file.close!
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/firmware/).to_stdout
  end
end
