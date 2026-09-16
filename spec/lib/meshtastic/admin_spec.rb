# frozen_string_literal: true

require 'spec_helper'

module AdminSpecHelpers
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
end

describe Meshtastic::Admin do
  include AdminSpecHelpers

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
end

module AdminSynchronousSpecHelpers
  include AdminSpecHelpers

  def responding_serial(&responder)
    handle = fake_serial_obj.merge(from_radio_queue: Queue.new, sent: [])
    handle[:serial_conn].define_singleton_method(:write) do |bytes|
      packet = Meshtastic::ToRadio.decode(bytes.byteslice(4..)).packet
      handle[:sent] << packet
      responder.call(handle, packet)
      bytes.bytesize
    end
    handle
  end

  def admin_reply(packet, from: packet.to, request_id: packet.id, message: nil)
    message ||= Meshtastic::AdminMessage.new(get_device_metadata_response: Meshtastic::DeviceMetadata.new(firmware_version: 'test-version'))
    Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: from, decoded: Meshtastic::Data.new(
      portnum: :ADMIN_APP, request_id: request_id, payload: message.to_proto
    )))
  end
end

describe Meshtastic::Admin, 'automatic sessions' do
  include AdminSynchronousSpecHelpers

  it 'automatically acquires and reuses a target-scoped session before remote writes' do
    handle = responding_serial do |connection, packet|
      message = Meshtastic::AdminMessage.decode(packet.decoded.payload)
      next unless message.get_config_request == :SESSIONKEY_CONFIG && message.payload_variant == :get_config_request

      reply = Meshtastic::AdminMessage.new(get_config_response: Meshtastic::Config.new, session_passkey: '12345678')
      connection[:from_radio_queue] << admin_reply(packet, message: reply)
    end
    2.times { described_class.set_owner(serial_obj: handle, to: '!aabbccdd', long_name: 'Remote', timeout: 0.2) }
    messages = handle[:sent].map { |packet| Meshtastic::AdminMessage.decode(packet.decoded.payload) }
    expect(messages.map(&:payload_variant)).to eq(%i[get_config_request set_owner set_owner])
    expect(messages.drop(1).map(&:session_passkey)).to eq(%w[12345678 12345678])
    described_class.set_owner(serial_obj: handle, to: '!aabbccee', long_name: 'Other', timeout: 0.2)
    expect(handle[:sent].length).to eq(5)
  end

  it 'returns a target ACK for a write and invalidates rejected sessions without replaying the write' do
    reason = :NONE
    handle = responding_serial do |connection, packet|
      message = Meshtastic::AdminMessage.decode(packet.decoded.payload)
      if message.payload_variant == :get_config_request
        reply = Meshtastic::AdminMessage.new(get_config_response: Meshtastic::Config.new, session_passkey: '12345678')
        connection[:from_radio_queue] << admin_reply(packet, message: reply)
      else
        connection[:from_radio_queue] << Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: packet.to,
                                                                                                      decoded: Meshtastic::Data.new(portnum: :ROUTING_APP, request_id: packet.id, payload: Meshtastic::Routing.new(error_reason: reason).to_proto)))
      end
    end
    options = { serial_obj: handle, to: '!aabbccdd', reboot_seconds: 5, timeout: 0.2 }
    expect(described_class.request(options)).to include(variant: :routing, value: :NONE)
    reason = :ADMIN_BAD_SESSION_KEY
    expect { described_class.request(options) }.to raise_error(Meshtastic::Admin::RoutingError)
    expect(handle[:sent].length).to eq(3)
    reason = :NONE
    described_class.request(options)
    expect(handle[:sent].length).to eq(5)
  end

  it 'caches the newest readback passkey, expires conservatively and supports explicit refresh' do
    key = 'freshkey'
    handle = responding_serial do |connection, packet|
      message = Meshtastic::AdminMessage.decode(packet.decoded.payload)
      next unless message.payload_variant.to_s.start_with?('get_')

      reply = Meshtastic::AdminMessage.new(get_config_response: Meshtastic::Config.new, session_passkey: key)
      connection[:from_radio_queue] << admin_reply(packet, message: reply)
    end
    options = { serial_obj: handle, to: '!aabbccdd', timeout: 0.5 }
    described_class.request(options.merge(get_config_request: :SESSIONKEY_CONFIG))
    described_class.reboot(options)
    expect(handle[:sent].length).to eq(2)
    handle[:admin_sessions][0xaabbccdd][:expires_at] = 0
    key = 'newerkey'
    described_class.reboot(options)
    expect(handle[:sent].length).to eq(4)
    expect(Meshtastic::AdminMessage.decode(handle[:sent].last.decoded.payload).session_passkey).to eq(key)
    described_class.reboot(options.merge(refresh_session: true))
    expect(handle[:sent].length).to eq(6)
  end

  it 'discards the old cache before a forced refresh which fails' do
    handle = responding_serial do |connection, packet|
      connection[:from_radio_queue] << admin_reply(packet, message: Meshtastic::AdminMessage.new(get_config_response: Meshtastic::Config.new))
    end
    handle[:admin_sessions] = { 0xaabbccdd => { key: 'old-key!', expires_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 100 } }
    options = { serial_obj: handle, to: '!aabbccdd', timeout: 0.2 }
    expect { described_class.reboot(options.merge(refresh_session: true)) }.to raise_error(ArgumentError, /eight-byte/)
    expect { described_class.reboot(options) }.to raise_error(ArgumentError, /eight-byte/)
    expect(handle[:sent].map { |packet| Meshtastic::AdminMessage.decode(packet.decoded.payload).payload_variant }).to eq(%i[get_config_request get_config_request])
  end

  it 'honors the session timeout even when only submission is requested' do
    handle = responding_serial { |_connection, _packet| nil }
    expect do
      Timeout.timeout(0.5, RuntimeError, 'outer deadline exceeded') do
        described_class.request(serial_obj: handle, to: '!aabbccdd', reboot_seconds: 5, wait: false, timeout: 0.15)
      end
    end.to raise_error(Timeout::Error, /Admin response/)
    expect(handle[:sent].length).to eq(1)
  end

  it 'rejects overlapping synchronous consumers on one handle without sending a second request' do
    entered = Queue.new
    release = Queue.new
    handle = responding_serial do |connection, packet|
      entered << true
      release.pop
      connection[:from_radio_queue] << admin_reply(packet)
    end
    worker = Thread.new { described_class.request(serial_obj: handle, get_device_metadata_request: true, timeout: 1) }
    entered.pop
    begin
      expect do
        Timeout.timeout(0.3) { described_class.request(serial_obj: handle, get_device_metadata_request: true, timeout: 0.1) }
      end.to raise_error(IOError, /already active/)
    ensure
      release << true
      release << true
      worker.value
    end
    expect(handle[:sent].length).to eq(1)
  end
end

describe Meshtastic::Admin, 'synchronous requests' do
  include AdminSynchronousSpecHelpers

  it 'ignores malformed routing payloads from unrelated senders' do
    unrelated = nil
    handle = responding_serial do |connection, packet|
      unrelated = Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: 77,
                                                                               decoded: Meshtastic::Data.new(portnum: :ROUTING_APP, request_id: packet.id, payload: "\xff".b)))
      connection[:from_radio_queue] << unrelated
      connection[:from_radio_queue] << admin_reply(packet)
    end
    expect(described_class.request(serial_obj: handle, get_device_metadata_request: true, timeout: 0.2)[:value].firmware_version).to eq('test-version')
    expect(handle[:from_radio_queue].pop(true)).to eq(unrelated)
  end

  %i[tcp_obj bluetooth_obj].each do |transport|
    it "reads correlated replies through the real #{transport} send path" do
      handle = if transport == :tcp_obj
                 responding_serial { |connection, packet| connection[:from_radio_queue] << admin_reply(packet) }
               else
                 { my_node_num: 0xb0b, from_radio_queue: Queue.new, tx_mutex: Mutex.new, bluetooth_conn: Object.new }
               end
      if transport == :bluetooth_obj
        make_reply = method(:admin_reply)
        handle[:bluetooth_conn].define_singleton_method(:write) do |bytes|
          packet = Meshtastic::ToRadio.decode(bytes).packet
          handle[:from_radio_queue] << make_reply.call(packet)
          bytes.bytesize
        end
      end
      result = described_class.request(transport => handle, get_device_metadata_request: true, timeout: 0.5)
      expect(result[:value].firmware_version).to eq('test-version')
    end
  end

  it 'bounds a silent receive and retains wrong-variant replies and text traffic on timeout' do
    preserved = []
    handle = responding_serial do |connection, packet|
      preserved << admin_reply(packet, message: Meshtastic::AdminMessage.new(get_owner_response: Meshtastic::User.new))
      preserved << Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: packet.to,
                                                                                decoded: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP, payload: 'keep')))
      preserved.each { |message| connection[:from_radio_queue] << message }
    end
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { described_class.request(serial_obj: handle, get_device_metadata_request: true, timeout: 0.15) }.to raise_error(Timeout::Error)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).to be < 0.6
    expect(preserved.map { handle[:from_radio_queue].pop(true) }).to eq(preserved)
  end

  it 'fails closed before writing when automatic session acquisition has no valid passkey' do
    handle = responding_serial do |connection, packet|
      connection[:from_radio_queue] << admin_reply(packet, message: Meshtastic::AdminMessage.new(get_config_response: Meshtastic::Config.new))
    end
    expect do
      described_class.reboot(serial_obj: handle, to: '!aabbccdd', timeout: 0.2)
    end.to raise_error(ArgumentError, /eight-byte passkey/)
    expect(handle[:sent].map { |packet| Meshtastic::AdminMessage.decode(packet.decoded.payload).payload_variant }).to eq([:get_config_request])
    expect do
      described_class.reboot(mqtt_obj: Object.new, to: '!aabbccdd')
    end.to raise_error(ArgumentError, /supply session_passkey/)
  end

  it 'rejects invalid timeouts before submitting any data' do
    handle = responding_serial { |_connection, _packet| raise 'must not send' }
    [0, -1, nil, Float::INFINITY, Float::NAN, '1'].each do |timeout|
      expect { described_class.request(serial_obj: handle, get_owner_request: true, timeout: timeout) }.to raise_error(ArgumentError, /timeout/)
    end
    expect(handle[:sent]).to be_empty
  end

  it 'keeps unrelated packets readable after the transport closes during a request' do
    unrelated = Meshtastic::FromRadio.new(log_record: Meshtastic::LogRecord.new(message: 'keep'))
    handle = responding_serial do |connection, _packet|
      connection[:from_radio_queue] << unrelated
      connection[:from_radio_queue].close
    end
    expect do
      described_class.request(serial_obj: handle, get_owner_request: true, timeout: 0.2)
    end.to raise_error(Timeout::Error)
    expect(handle[:from_radio_queue].pop(true)).to eq(unrelated)
    expect(handle[:from_radio_queue]).to be_closed
  end

  it 'reports correlated routing failures without mistaking a local ACK for remote readback' do
    handle = responding_serial do |connection, packet|
      [connection[:my_node_num], packet.to].each do |sender|
        routing = Meshtastic::Routing.new(error_reason: sender == packet.to ? :NOT_AUTHORIZED : :NONE)
        connection[:from_radio_queue] << Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(
          from: sender, decoded: Meshtastic::Data.new(portnum: :ROUTING_APP, request_id: packet.id, payload: routing.to_proto)
        ))
      end
    end
    expect do
      described_class.request(serial_obj: handle, to: '!aabbccdd', get_device_metadata_request: true, timeout: 0.1)
    end.to raise_error(Meshtastic::Admin::RoutingError, /NOT_AUTHORIZED/)
    expect(handle[:from_radio_queue].size).to eq(1)
  end

  it 'waits for the target-correlated metadata response and preserves unrelated packets' do
    unrelated = []
    handle = responding_serial do |connection, packet|
      unrelated << admin_reply(packet, from: 123)
      unrelated << admin_reply(packet, request_id: packet.id + 1)
      unrelated << Meshtastic::FromRadio.new(log_record: Meshtastic::LogRecord.new(message: 'other traffic'))
      unrelated.each { |message| connection[:from_radio_queue] << message }
      connection[:from_radio_queue] << admin_reply(packet)
    end
    result = described_class.request(serial_obj: handle, message: Meshtastic::AdminMessage.new(get_device_metadata_request: true), timeout: 0.2)
    expect(result[:value].firmware_version).to eq('test-version')
    expect(result[:request_id]).to eq(handle[:sent].last.id)
    expect(unrelated.map { handle[:from_radio_queue].pop(true) }).to eq(unrelated)
  end
end

describe Meshtastic::Admin, 'generated schema coverage' do
  Meshtastic::AdminMessage.descriptor.lookup_oneof('payload_variant').each do |field|
    it "round-trips the #{field.name} payload without changing its oneof selection" do
      value = case field.type
              when :message then field.subtype.msgclass.new
              when :bool then false
              when :string then ''
              when :enum then 0
              else 1
              end
      message = described_class.encode(field.name.to_sym => value)
      decoded = described_class.decode(payload: message.to_proto)
      expect(decoded.payload_variant).to eq(field.name.to_sym)
      expect(decoded.public_send(field.name)).to eq(message.public_send(field.name))
    end
  end
end

describe Meshtastic::Admin, 'validation and response handling' do
  include AdminSpecHelpers

  it 'converts a zero-based channel index exactly once and rejects invalid indexes' do
    serial_obj = fake_serial_obj
    [0, 7].each do |index|
      serial_obj[:written].clear
      described_class.get_channel(serial_obj: serial_obj, index: index)
      expect(decode_admin(serial_obj).last.get_channel_request).to eq(index + 1)
    end
    [-1, 8, '1', 1.5].each do |index|
      expect { described_class.get_channel(serial_obj: serial_obj, index: index) }.to raise_error(ArgumentError)
    end
  end

  it 'rejects conflicting, empty and unknown payloads without mutating caller messages' do
    original = Meshtastic::AdminMessage.new(get_owner_request: true)
    expect { described_class.encode(message: original, reboot_seconds: 5) }.to raise_error(ArgumentError, /one payload/)
    expect(original.payload_variant).to eq(:get_owner_request)
    expect { described_class.encode(get_owner_request: true, sensor_config: Meshtastic::SensorConfig.new) }.to raise_error(ArgumentError, /one payload/)
    expect { described_class.encode(set_owner: nil) }.to raise_error(ArgumentError)
    expect { described_class.encode(rebot_seconds: 5) }.to raise_error(ArgumentError)
    encoded = described_class.encode(message: original, session_passkey: '12345678')
    expect(encoded.session_passkey).to eq('12345678')
    expect(original.session_passkey).to eq('')
    expect(described_class.encode(get_config_request: :DEVICE_CONFIG).payload_variant).to eq(:get_config_request)
    expect(described_class.encode(nodedb_reset: false).payload_variant).to eq(:nodedb_reset)
  end

  it 'targets the connected node locally and requests replies only for getters by default' do
    serial_obj = fake_serial_obj
    described_class.reboot(serial_obj: serial_obj)
    packet, = decode_admin(serial_obj)
    expect(packet.to).to eq(0xb0b)
    expect(packet.from).to eq(0)
    expect(packet.decoded.want_response).to be(false)
    serial_obj[:written].clear
    described_class.get_owner(serial_obj: serial_obj)
    expect(decode_admin(serial_obj).first.decoded.want_response).to be(true)
    serial_obj[:written].clear
    described_class.reboot(serial_obj: serial_obj, to: '!aabbccdd', want_response: true, auto_session: false)
    expect(decode_admin(serial_obj).first.to).to eq(0xaabbccdd)
    expect(decode_admin(serial_obj).first.decoded.want_response).to be(true)
    expect { described_class.get_owner(mqtt_obj: Object.new) }.to raise_error(ArgumentError, /destination/)
    expect { described_class.get_owner(serial_obj: serial_obj, to: '!ffffffff') }.to raise_error(ArgumentError, /destination/)
  end

  it 'decodes admin responses and correlates without consuming transport queues' do
    admin = Meshtastic::AdminMessage.new(get_owner_response: Meshtastic::User.new(long_name: 'Remote'), session_passkey: '12345678')
    packet = Meshtastic::MeshPacket.new(from: 0xaabbccdd, decoded: Meshtastic::Data.new(portnum: :ADMIN_APP, payload: admin.to_proto, request_id: 42))
    frame = Meshtastic::FromRadio.new(packet: packet)
    expect(described_class.decode(payload: admin.to_proto)).to eq(admin)
    expect(described_class.decode(packet: frame)).to eq(admin)
    result = described_class.response(packet: frame, request_id: 42, from: 0xaabbccdd)
    expect(result).to include(variant: :get_owner_response, value: admin.get_owner_response, session_passkey: '12345678', request_id: 42, from: 0xaabbccdd)
    expect(described_class.response(packet: frame, request_id: 43)).to be_nil
    expect(described_class.response(packet: frame, from: 123)).to be_nil
    packet.decoded.portnum = :TEXT_MESSAGE_APP
    expect(described_class.response(packet: packet)).to be_nil
    expect { described_class.decode(packet: packet) }.to raise_error(ArgumentError, /ADMIN_APP/)
  end

  it 'supports OTA wire operations and resetting all nodes explicitly' do
    serial_obj = fake_serial_obj
    event = Meshtastic::AdminMessage::OTAEvent.new(reboot_ota_mode: :OTA_BLE, ota_hash: 'x' * 32)
    described_class.ota_request(serial_obj: serial_obj, event: event)
    expect(decode_admin(serial_obj).last.ota_request).to eq(event)
    serial_obj[:written].clear
    described_class.reboot_ota(serial_obj: serial_obj, seconds: -1)
    expect(decode_admin(serial_obj).last.reboot_ota_seconds).to eq(-1)
    serial_obj[:written].clear
    described_class.nodedb_reset(serial_obj: serial_obj, preserve_favorites: false)
    expect(decode_admin(serial_obj).last.payload_variant).to eq(:nodedb_reset)
    expect(decode_admin(serial_obj).last.nodedb_reset).to be(false)
  end

  it 'does not turn omitted required values into zero or empty destructive commands' do
    serial_obj = fake_serial_obj
    %i[delete_file set_scale set_time set_canned_messages set_ringtone remove_by_nodenum set_favorite_node remove_favorite_node set_ignored_node remove_ignored_node toggle_muted_node].each do |method|
      expect { described_class.public_send(method, serial_obj: serial_obj) }.to raise_error(ArgumentError), method.to_s
    end
    expect(serial_obj[:written]).to be_empty
    described_class.set_canned_messages(serial_obj: serial_obj, messages: '')
    expect(decode_admin(serial_obj).last.payload_variant).to eq(:set_canned_message_module_messages)
  end

  it 'returns the actual transmitted request ID for later response correlation' do
    serial_obj = fake_serial_obj
    result = described_class.request(serial_obj: serial_obj, get_owner_request: true, request_id: 1234, wait: false)
    expect(result[:request_id]).to eq(1234)
    expect(decode_admin(serial_obj).first.id).to eq(1234)
    expect { described_class.request(serial_obj: serial_obj, get_owner_request: true, request_id: 0) }.to raise_error(ArgumentError)
    serial_obj[:written].clear
    result = described_class.request(serial_obj: serial_obj, get_config_request: :SESSIONKEY_CONFIG, wait: false)
    expect(result[:request_id]).to eq(decode_admin(serial_obj).first.id)
    expect(result[:request_id]).to be_positive
  end

  it 'requires an eight-byte session passkey when explicitly supplied' do
    [nil, '', 'short', 'x' * 9].each do |key|
      expect { described_class.encode(get_owner_request: true, session_passkey: key) }.to raise_error(ArgumentError, /eight bytes/)
    end
    expect(described_class.encode(get_owner_request: true, session_passkey: "\x00" * 8).session_passkey.bytesize).to eq(8)
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
