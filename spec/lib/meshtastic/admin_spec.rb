# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Admin do
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

  def decode_admin(serial_obj)
    frame = serial_obj[:written]
    body = frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))
    packet = Meshtastic::ToRadio.decode(body).packet
    [packet, Meshtastic::AdminMessage.decode(packet.decoded.payload)]
  end

  it 'sends a reboot AdminMessage on ADMIN_APP' do
    serial_obj = fake_serial_obj
    described_class.reboot(serial_obj: serial_obj, seconds: 7)
    packet, admin = decode_admin(serial_obj)
    expect(packet.decoded.portnum).to eq(:ADMIN_APP)
    expect(admin.reboot_seconds).to eq(7)
  end

  it 'sends a set_owner AdminMessage' do
    serial_obj = fake_serial_obj
    described_class.set_owner(serial_obj: serial_obj, long_name: 'Test Node', short_name: 'TN')
    _packet, admin = decode_admin(serial_obj)
    expect(admin.set_owner.long_name).to eq('Test Node')
    expect(admin.set_owner.short_name).to eq('TN')
  end

  it 'covers remaining AdminMessage request fields' do
    serial_obj = fake_serial_obj
    examples = {
      get_module_config: %i[get_module_config_request MQTT_CONFIG],
      get_canned_messages: [:get_canned_message_module_messages_request, true],
      get_device_metadata: [:get_device_metadata_request, true],
      get_ringtone: [:get_ringtone_request, true],
      get_device_connection_status: [:get_device_connection_status_request, true],
      get_node_remote_hardware_pins: [:get_node_remote_hardware_pins_request, true],
      get_ui_config: [:get_ui_config_request, true],
      enter_dfu: [:enter_dfu_mode_request, true],
      begin_edit: [:begin_edit_settings, true],
      commit_edit: [:commit_edit_settings, true],
      remove_fixed_position: [:remove_fixed_position, true],
      exit_simulator: [:exit_simulator, true],
      nodedb_reset: [:nodedb_reset, true]
    }
    examples.each do |meth, (field, expected)|
      serial_obj[:written].clear
      described_class.public_send(meth, serial_obj: serial_obj)
      _packet, admin = decode_admin(serial_obj)
      expect(admin.public_send(field)).to eq(expected), meth.to_s
    end
  end

  it 'sends factory resets, file delete, favorites, and edit transactions' do
    serial_obj = fake_serial_obj
    described_class.factory_reset_config(serial_obj: serial_obj)
    expect(decode_admin(serial_obj).last.factory_reset_config).to eq(1)
    serial_obj[:written].clear
    described_class.factory_reset_device(serial_obj: serial_obj)
    expect(decode_admin(serial_obj).last.factory_reset_device).to eq(1)
    serial_obj[:written].clear
    described_class.delete_file(serial_obj: serial_obj, path: '/prefs.json')
    expect(decode_admin(serial_obj).last.delete_file_request).to eq('/prefs.json')
    serial_obj[:written].clear
    described_class.set_favorite_node(serial_obj: serial_obj, node_num: 0xb0b)
    expect(decode_admin(serial_obj).last.set_favorite_node).to eq(0xb0b)
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
