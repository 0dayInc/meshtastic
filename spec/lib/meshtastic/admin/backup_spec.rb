# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'meshtastic/admin/backup' if File.exist?(File.expand_path('../../../../lib/meshtastic/admin/backup.rb', __dir__))

# Stateful peer decodes actual production Serial ToRadio frames and encodes replies.
class BackupRadioPeer
  attr_reader :handle, :sent, :state, :packets
  attr_accessor :fail_on, :silent_on, :drop_ack_on

  def initialize
    @sent = []
    @packets = []
    @state = {
      owner: Meshtastic::User.new(id: '!aabbccdd', long_name: 'Backup node', short_name: 'BN', macaddr: 'secret', hw_model: :UNSET),
      device: Meshtastic::Config.new(device: { serial_enabled: false }),
      network: Meshtastic::Config.new(network: { wifi_enabled: true, wifi_psk: 'password' }),
      mqtt: Meshtastic::ModuleConfig.new(mqtt: { enabled: false, password: 'broker-secret' }),
      channel: Meshtastic::Channel.new(index: 0, role: :PRIMARY, settings: { psk: "\x00\xff".b, name: 'Test' }),
      ui: Meshtastic::DeviceUIConfig.new(calibration_data: "\x00\xff".b)
    }
    @handle = { serial_conn: self, my_node_num: 0xaabbccdd, from_radio_queue: Queue.new }
  end

  def write(bytes)
    raise 'invalid serial frame' unless bytes.byteslice(0, 2) == "\x94\xc3".b && bytes.byteslice(2, 2).unpack1('n') == bytes.bytesize - 4

    packet = Meshtastic::ToRadio.decode(bytes.byteslice(4..)).packet
    @packets << packet
    message = Meshtastic::AdminMessage.decode(packet.decoded.payload)
    @sent << message
    variant = message.payload_variant
    return bytes.bytesize if variant == silent_on

    value = case variant
            when :get_owner_request then state[:owner]
            when :get_config_request then state[message.get_config_request.to_s.delete_suffix('_CONFIG').downcase.to_sym]
            when :get_module_config_request then state.fetch(message.get_module_config_request, state[:mqtt])
            when :get_channel_request then state.fetch(message.get_channel_request - 1, state[:channel])
            when :get_ui_config_request then state[:ui]
            when :get_ringtone_request then state[:ringtone]
            when :get_canned_message_module_messages_request then state[:canned_messages]
            end
    if value
      response = Meshtastic::AdminMessage.new(variant.to_s.sub(/request$/, 'response').to_sym => value, session_passkey: 'passkey!')
      data = Meshtastic::Data.new(portnum: :ADMIN_APP, request_id: packet.id, payload: response.to_proto)
    else
      @state[:owner] = message.set_owner if variant == :set_owner
      @state[message.set_config.payload_variant] = message.set_config if variant == :set_config
      @state[:channel] = message.set_channel if variant == :set_channel
      @state[:ringtone] = message.set_ringtone_message if variant == :set_ringtone_message
      @state[:canned_messages] = message.set_canned_message_module_messages if variant == :set_canned_message_module_messages
      if variant == :set_module_config
        index = Meshtastic::ModuleConfig.descriptor.map(&:name).index(message.set_module_config.payload_variant.to_s)
        @state[Meshtastic::Admin::Backup::MODULE_TYPES[index]] = message.set_module_config
      end
      return bytes.bytesize if variant == drop_ack_on

      reason = variant == fail_on ? :NOT_AUTHORIZED : :NONE
      data = Meshtastic::Data.new(portnum: :ROUTING_APP, request_id: packet.id, payload: Meshtastic::Routing.new(error_reason: reason).to_proto)
    end
    response = Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: packet.to, decoded: data))
    handle[:from_radio_queue] << Meshtastic::FromRadio.decode(response.to_proto)
    bytes.bytesize
  end

  def flush; end
  def closed? = false
end

describe 'Meshtastic::Admin::Backup' do
  let(:backup_api) { Meshtastic::Admin.const_get(:Backup) }
  let(:peer) { BackupRadioPeer.new }
  let(:options) { { transport_obj: peer.handle, config_types: [:DEVICE_CONFIG], module_config_types: [:MQTT_CONFIG], channel_indexes: [0], include_ui: true, timeout: 0.3 } }

  it 'exports binary DeviceProfile bytes with fresh values and presence-aware semantic round trips' do
    peer.state[:owner].is_unmessagable = false
    peer.state[:channel].settings.psk = "\x01".b
    peer.state[:lora] = Meshtastic::Config.new(lora: { region: :US })
    result = backup_api.export(options.merge(format: :device_profile, include_ui: false, config_types: %i[DEVICE_CONFIG LORA_CONFIG]))
    expect(result).to include(status: :exported, count: 5, format: :device_profile)
    expect(result[:backup].encoding).to eq(Encoding::BINARY)
    profile = Meshtastic::DeviceProfile.decode(result[:backup])
    expect(profile.long_name).to eq(peer.state[:owner].long_name)
    expect(profile.has_is_licensed?).to be_truthy
    expect(profile.is_licensed).to be(false)
    expect(profile.has_is_unmessagable?).to be_truthy
    expect(profile.is_unmessagable).to be(false)
    expect(profile.config.device).to eq(peer.state[:device].device)
    expect(profile.module_config.mqtt).to eq(peer.state[:mqtt].mqtt)
    channels = Meshtastic::Admin::Channel.import_url(url: profile.channel_url)
    expect(channels.settings.first).to eq(peer.state[:channel].settings)
    expect(channels.lora_config).to eq(profile.config.lora)
    expect(result[:backup]).not_to include('passkey!', '!aabbccdd')
    peer.sent.clear
    plan = backup_api.import(transport_obj: peer.handle, backup: result[:backup], dry_run: true)
    expect(plan[:planned]).to eq(result[:count])
    expect(peer.sent).to be_empty
    restored = backup_api.import(transport_obj: peer.handle, backup: result[:backup], verify: true, timeout: 0.3)
    expect(restored).to include(status: :readback_matched, acknowledged: 5)
  end

  it 'rejects incompatible binary selections before any requests or file creation' do
    [{ include_ui: true }, { channel_indexes: [1] }, { channel_indexes: [1, 0] },
     { format: :auto }, { format: nil }, { format: :unknown },
     { config_types: [], module_config_types: [], channel_indexes: [], include_owner: false }].each do |invalid|
      expect { backup_api.export(options.merge(format: :device_profile, include_ui: false).merge(invalid)) }.to raise_error(ArgumentError)
      expect(peer.sent).to be_empty
    end
  end

  it 'writes exclusive binary 0600 files and rejects unrepresentable returned channels' do
    peer.state[:channel].settings.psk = "\x01".b
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'backup.cfg')
      opts = options.merge(format: :device_profile, include_ui: false, path: path)
      result = backup_api.export(opts)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(File.binread(path)).to eq(result[:backup])
      expect { backup_api.export(opts) }.to raise_error(Errno::EEXIST)
      link = File.join(directory, 'link.cfg')
      File.symlink(path, link)
      expect { backup_api.export(opts.merge(path: link)) }.to raise_error(SystemCallError)
      peer.sent.clear
      expect(backup_api.import(transport_obj: peer.handle, path: path, dry_run: true)[:planned]).to eq(result[:count])
      expect(peer.sent).to be_empty
      profile = Meshtastic::DeviceProfile.decode(result[:backup])
      expect(profile.has_is_unmessagable?).to be_falsey
      expect(profile.has_fixed_position?).to be_falsey
      expect(profile.has_ringtone?).to be_falsey
      expect(profile.has_canned_messages?).to be_falsey
      expect(Meshtastic::Admin::Channel.import_url(url: profile.channel_url).lora_config).to be_nil
      peer.state[:channel].role = :DISABLED
      expect { backup_api.export(opts.merge(path: File.join(directory, 'bad.cfg'))) }.to raise_error(ArgumentError, /round-trip/)
      expect(File.exist?(File.join(directory, 'bad.cfg'))).to be(false)
    end
  end

  it 'exports explicit fixed position and fresh optional strings without losing zero or empty presence' do
    peer.state[:ringtone] = ''
    peer.state[:canned_messages] = ''
    opts = options.merge(format: :device_profile, include_owner: false, include_ui: false, config_types: [], module_config_types: [], channel_indexes: [],
                         fixed_position: { latitude_i: 0, longitude_i: 0, altitude: 0 }, include_ringtone: true, include_canned_messages: true)
    result = backup_api.export(opts)
    expect(result[:count]).to eq(3)
    profile = Meshtastic::DeviceProfile.decode(result[:backup])
    expect(profile.fixed_position).to eq(Meshtastic::Position.new(opts[:fixed_position]))
    expect(profile.has_ringtone?).to be_truthy
    expect(profile.ringtone).to eq('')
    expect(profile.has_canned_messages?).to be_truthy
    expect(profile.canned_messages).to eq('')
    expect(peer.sent.map(&:payload_variant)).to eq(%i[get_ringtone_request get_canned_message_module_messages_request])
    peer.sent.clear
    expect(backup_api.import(transport_obj: peer.handle, backup: result[:backup], dry_run: true)[:planned]).to eq(3)
    expect(peer.sent).to be_empty
    [nil, 'bad', { unknown: 1 }].each do |position|
      expect { backup_api.export(opts.merge(fixed_position: position)) }.to raise_error(ArgumentError)
      expect(peer.sent).to be_empty
    end
    %i[fixed_position include_ringtone include_canned_messages].each do |key|
      expect { backup_api.export(options.merge(key => opts[key])) }.to raise_error(ArgumentError)
      expect(peer.sent).to be_empty
    end
  end

  it 'exports all core and module sections with present empty messages' do
    Meshtastic::Config.descriptor.to_a.take(8).each do |field|
      peer.state[field.name.to_sym] = Meshtastic::Config.new(field.name.to_sym => {})
    end
    Meshtastic::ModuleConfig.descriptor.each_with_index do |field, index|
      peer.state[backup_api::MODULE_TYPES[index]] = Meshtastic::ModuleConfig.new(field.name.to_sym => {})
    end
    result = backup_api.export(options.merge(format: :device_profile, include_owner: false, include_ui: false, channel_indexes: [],
                                             config_types: backup_api::CONFIG_TYPES, module_config_types: backup_api::MODULE_TYPES))
    expect(result[:count]).to eq(25)
    profile = Meshtastic::DeviceProfile.decode(result[:backup])
    expect(profile.has_channel_url?).to be_falsey
    expect(profile.has_long_name?).to be_falsey
    Meshtastic::Config.descriptor.to_a.take(8).each { |field| expect(profile.config[field.name]).to eq(peer.state[field.name.to_sym][field.name]) }
    Meshtastic::ModuleConfig.descriptor.each_with_index do |field, index|
      expect(profile.module_config[field.name]).to eq(peer.state[backup_api::MODULE_TYPES[index]][field.name])
    end
    peer.sent.clear
    expect(backup_api.import(transport_obj: peer.handle, backup: result[:backup], dry_run: true)[:planned]).to eq(25)
    expect(peer.sent).to be_empty
    peer.state[:device] = Meshtastic::Config.new(network: {})
    expect { backup_api.export(options.merge(format: :device_profile, include_ui: false, channel_indexes: [])) }.to raise_error(ArgumentError, /slot/)
  end

  it 'documents the complete export format and selection API in runtime help' do
    expect { backup_api.help }.to output(/Backup.export.*format:.*:json.*:device_profile.*path:.*fixed_position:.*include_ringtone:.*include_canned_messages:.*channel:.*hop_limit:.*Backup.import/m).to_stdout
  end

  it 'preserves multiple ordered channels and never creates binary files on read timeout' do
    peer.state[:channel].settings.psk = "\x01".b
    peer.state[1] = Meshtastic::Channel.new(index: 1, role: :SECONDARY, settings: { name: 'Second', psk: "\x00".b })
    opts = options.merge(format: :device_profile, include_ui: false, channel_indexes: [0, 1])
    profile = Meshtastic::DeviceProfile.decode(backup_api.export(opts)[:backup])
    expect(Meshtastic::Admin::Channel.import_url(url: profile.channel_url).settings.to_a).to eq([peer.state[:channel].settings, peer.state[1].settings])
    expect(backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, dry_run: true)[:plan]).to include(section: 'channel', slot: 1)
    peer.silent_on = :get_config_request
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'incomplete.cfg')
      expect { backup_api.export(opts.merge(path: path, timeout: 0.1)) }.to raise_error(Timeout::Error)
      expect(File.exist?(path)).to be(false)
    end
  end
end

describe 'Meshtastic::Admin::Backup import and JSON export' do
  let(:backup_api) { Meshtastic::Admin.const_get(:Backup) }
  let(:peer) { BackupRadioPeer.new }
  let(:options) { { transport_obj: peer.handle, config_types: [:DEVICE_CONFIG], module_config_types: [:MQTT_CONFIG], channel_indexes: [0], include_ui: true, timeout: 0.3 } }

  it 'restores every DeviceProfile section, including present empty strings, false flags and zero coordinates' do
    config = Meshtastic::LocalConfig.new(version: 24)
    Meshtastic::Config.descriptor.to_a.take(8).each { |field| config[field.name] = field.subtype.msgclass.new }
    modules = Meshtastic::LocalModuleConfig.new(version: 24)
    Meshtastic::ModuleConfig.descriptor.each { |field| modules[field.name] = field.subtype.msgclass.new }
    config.security = Meshtastic::Config::SecurityConfig.new(private_key: "\x00\xff".b, admin_key: ['synthetic-key'], serial_enabled: false)
    config.lora = Meshtastic::Config::LoRaConfig.new(region: :US, tx_power: -1, frequency_offset: 1.25, ignore_incoming: [1, 0xffffffff])
    modules.mqtt = Meshtastic::ModuleConfig::MQTTConfig.new(enabled: false, password: 'synthetic-password')
    channels = Meshtastic::ChannelSet.new(settings: [{ name: 'test', psk: "\x01".b }], lora_config: config.lora)
    profile = Meshtastic::DeviceProfile.new(long_name: 'Profile', short_name: '', is_licensed: false, is_unmessagable: false,
                                            config: config, module_config: modules, channel_url: "https://meshtastic.org/e/##{Base64.urlsafe_encode64(channels.to_proto, padding: false)}",
                                            fixed_position: { latitude_i: 0, longitude_i: 0, altitude: 0 }, ringtone: '', canned_messages: '')
    result = backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, format: :device_profile, verify: true, timeout: 0.3)
    expect(result).to include(status: :readback_incomplete, planned: 30, acknowledged: 30, readback_matched: 29)
    expect(result[:records].find { |record| record[:section] == 'fixed_position' }).to include(readback: :unsupported)
    expect(peer.state[:owner]).to eq(Meshtastic::User.new(long_name: 'Profile', short_name: '', is_licensed: false, is_unmessagable: false))
    expect(peer.state[:owner].has_is_unmessagable?).to be_truthy
    expect(peer.sent.find { |message| message.payload_variant == :set_fixed_position }.set_fixed_position).to eq(profile.fixed_position)
    expect(peer.sent.find { |message| message.payload_variant == :set_ringtone_message }.set_ringtone_message).to eq('')
    expect(peer.sent.find { |message| message.payload_variant == :set_canned_message_module_messages }.set_canned_message_module_messages).to eq('')
    expect(peer.state[:channel].settings).to eq(channels.settings.first)
    config.class.descriptor.each do |field|
      next if field.name == 'version'

      expect(peer.state[field.name.to_sym][field.name]).to eq(config[field.name])
    end
    Meshtastic::ModuleConfig.descriptor.each_with_index do |field, index|
      expect(peer.state[backup_api::MODULE_TYPES[index]][field.name]).to eq(modules[field.name])
    end
    expect(result.inspect).not_to include('synthetic-password', 'synthetic-key')
  end

  it 'imports binary DeviceProfile config presence and scalar defaults without radio requests in dry runs' do
    profile = Meshtastic::DeviceProfile.new(config: { device: { serial_enabled: false }, power: {} }, module_config: { mqtt: { enabled: false } })
    result = backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, format: :device_profile, dry_run: true)
    expect(result[:plan]).to eq([{ section: 'config', slot: 'DEVICE_CONFIG' }, { section: 'config', slot: 'POWER_CONFIG' }, { section: 'module_config', slot: 'MQTT_CONFIG' }])
    expect(peer.sent).to be_empty
    result = backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, format: :device_profile, timeout: 0.3)
    expect(result[:acknowledged]).to eq(3)
    expect(peer.sent.map { |message| message.public_send(message.payload_variant) }).to eq([
                                                                                             Meshtastic::Config.new(device: { serial_enabled: false }),
                                                                                             Meshtastic::Config.new(power: {}),
                                                                                             Meshtastic::ModuleConfig.new(mqtt: { enabled: false })
                                                                                           ])
  end

  it 'validates and dry-runs a complete document without any radio writes' do
    document = backup_api.export(options)[:backup]
    peer.sent.clear
    result = backup_api.import(transport_obj: peer.handle, backup: document, dry_run: true)
    expect(result).to include(status: :dry_run, planned: 5, acknowledged: 0, persistence_verified: false)
    expect(result[:plan]).to eq([
                                  { section: 'owner', slot: nil }, { section: 'config', slot: 'DEVICE_CONFIG' },
                                  { section: 'module_config', slot: 'MQTT_CONFIG' }, { section: 'ui', slot: nil }, { section: 'channel', slot: 0 }
                                ])
    expect(peer.sent).to be_empty
    invalid = Marshal.load(Marshal.dump(document))
    invalid['records'].last['value']['calibration_data'] = '%%%'
    expect { backup_api.import(transport_obj: peer.handle, backup: invalid) }.to raise_error(ArgumentError)
    expect(peer.sent).to be_empty
  end

  it 'restores exact protobuf values with disruptive settings last and explicit edit ACKs' do
    document = backup_api.export(options.merge(config_types: %i[NETWORK_CONFIG DEVICE_CONFIG]))[:backup]
    peer.sent.clear
    result = backup_api.import(transport_obj: peer.handle, backup: document, edit_transaction: true, timeout: 0.3)
    expect(result).to include(status: :acknowledged, planned: 6, acknowledged: 6, persistence_verified: false, transaction: :commit_acknowledged)
    expect(peer.sent.first.payload_variant).to eq(:begin_edit_settings)
    expect(peer.sent.last.payload_variant).to eq(:commit_edit_settings)
    expect(peer.sent[-2].set_config.payload_variant).to eq(:network)
    expect(peer.sent.find { |m| m.payload_variant == :set_channel }.set_channel).to eq(peer.state[:channel])
    expect(peer.sent.find { |m| m.payload_variant == :store_ui_config }.store_ui_config).to eq(peer.state[:ui])
    expect(peer.state[:owner].id).to eq('')
  end

  it 'stops on a routing failure without commit or replay and reports acknowledged versus uncertain records' do
    document = backup_api.export(options)[:backup]
    peer.sent.clear
    peer.fail_on = :set_module_config
    result = backup_api.import(transport_obj: peer.handle, backup: document, edit_transaction: true, timeout: 0.3)
    expect(result).to include(status: :partial_failure, acknowledged: 2, attempted: 3, transaction: :open)
    expect(result[:failure]).to include(section: 'module_config', error: 'Meshtastic::Admin::RoutingError', reason: :NOT_AUTHORIZED)
    expect(peer.sent.map(&:payload_variant)).to eq(%i[begin_edit_settings set_owner set_config set_module_config])
  end

  it 'continues after a lost MQTT write ACK only on a fresh matching read without replay' do
    document = backup_api.export(options)[:backup]
    peer.sent.clear
    peer.drop_ack_on = :set_module_config
    result = backup_api.import(transport_obj: peer.handle, backup: document, edit_transaction: true, timeout: 0.15)
    expect(result).to include(status: :applied, acknowledged: 4, readback_confirmed: 1, attempted: 5,
                              persistence_verified: false, transaction: :commit_acknowledged)
    expect(result[:records][2]).to include(section: 'module_config', slot: 'MQTT_CONFIG', status: :readback_confirmed)
    expect(peer.sent.map(&:payload_variant)).to eq(%i[begin_edit_settings set_owner set_config set_module_config get_module_config_request store_ui_config set_channel commit_edit_settings])
    expect(result.inspect).not_to include('broker-secret', 'passkey!')
  end

  it 'reports a missing commit ACK as uncertain without replaying' do
    document = backup_api.export(options)[:backup]
    peer.sent.clear
    peer.silent_on = :commit_edit_settings
    result = backup_api.import(transport_obj: peer.handle, backup: document, edit_transaction: true, timeout: 0.1)
    expect(result).to include(status: :partial_failure, acknowledged: 5, transaction: :commit_uncertain)
    expect(result[:failure]).to include(operation: :commit_edit_settings, error: 'Timeout::Error')
    expect(peer.sent.count { |m| m.payload_variant == :commit_edit_settings }).to eq(1)
  end

  it 'writes exclusive 0600 JSON files and accepts only one import source, rejecting symlinks' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'backup.json')
      result = backup_api.export(options.merge(path: path))
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(JSON.parse(File.read(path))).to eq(result[:backup])
      expect { backup_api.export(options.merge(path: path)) }.to raise_error(Errno::EEXIST)
      link = File.join(directory, 'link.json')
      File.symlink(path, link)
      expect { backup_api.export(options.merge(path: link)) }.to raise_error(SystemCallError)
      expect { backup_api.import(transport_obj: peer.handle, path: link, dry_run: true) }.to raise_error(SystemCallError)
      peer.sent.clear
      expect(backup_api.import(transport_obj: peer.handle, path: path, dry_run: true)[:planned]).to eq(5)
      expect { backup_api.import(transport_obj: peer.handle, path: path, backup: result[:backup]) }.to raise_error(ArgumentError)
      expect(peer.sent).to be_empty
    end
  end
end

describe 'Meshtastic::Admin::Backup missing write ACK recovery' do
  let(:backup_api) { Meshtastic::Admin::Backup }
  let(:peer) { BackupRadioPeer.new }
  let(:profile) { Meshtastic::DeviceProfile.new(module_config: { mqtt: { enabled: true, password: 'synthetic-secret' } }, config: { lora: { region: :US } }) }
  let(:options) { { transport_obj: peer.handle, backup: profile.to_proto, edit_transaction: true, timeout: 0.15 } }

  before { peer.drop_ack_on = :set_module_config }

  it 'fails closed when a fresh read differs, including redacted secrets' do
    allow(peer).to receive(:write).and_wrap_original do |original, bytes|
      result = original.call(bytes)
      peer.state[:MQTT_CONFIG].mqtt.password = '' if peer.sent.last.payload_variant == :set_module_config
      result
    end
    result = backup_api.import(options)
    expect(result).to include(status: :partial_failure, acknowledged: 0, readback_confirmed: 0, attempted: 1, transaction: :open)
    expect(result[:failure]).to include(operation: :set_module_config, error: 'Timeout::Error', readback: :mismatch)
    expect(peer.sent.map(&:payload_variant)).to eq(%i[begin_edit_settings set_module_config get_module_config_request])
    expect(result.inspect).not_to include('synthetic-secret')
  end

  it 'stops on getter timeout without later writes, commit or replay' do
    peer.silent_on = :get_module_config_request
    result = backup_api.import(options)
    expect(result).to include(status: :partial_failure, acknowledged: 0, readback_confirmed: 0, transaction: :open)
    expect(result[:failure]).to include(error: 'Timeout::Error', readback: :failed)
    expect(peer.sent.map(&:payload_variant)).to eq(%i[begin_edit_settings set_module_config get_module_config_request])
  end

  it 'never recovers a routing rejection even if the peer stored the requested state' do
    peer.drop_ack_on = nil
    peer.fail_on = :set_module_config
    result = backup_api.import(options)
    expect(result).to include(status: :partial_failure, readback_confirmed: 0, transaction: :open)
    expect(result[:failure]).to include(error: 'Meshtastic::Admin::RoutingError', reason: :NOT_AUTHORIZED)
    expect(peer.sent.map(&:payload_variant)).to eq(%i[begin_edit_settings set_module_config])
  end

  it 'keeps a correlated getter routing rejection fatal during timeout recovery' do
    allow(peer).to receive(:write).and_wrap_original do |original, bytes|
      result = original.call(bytes)
      if peer.sent.last.payload_variant == :get_module_config_request
        response = peer.handle[:from_radio_queue].pop(true)
        response.packet.decoded.portnum = :ROUTING_APP
        response.packet.decoded.payload = Meshtastic::Routing.new(error_reason: :NOT_AUTHORIZED).to_proto
        peer.handle[:from_radio_queue] << response
      end
      result
    end
    result = backup_api.import(options)
    expect(result).to include(status: :partial_failure, readback_confirmed: 0, transaction: :open)
    expect(result[:failure]).to include(readback: :failed, error: 'Meshtastic::Admin::RoutingError', reason: :NOT_AUTHORIZED)
    expect(peer.sent.map(&:payload_variant)).to eq(%i[begin_edit_settings set_module_config get_module_config_request])
  end

  it 'does not recover non-timeout write errors' do
    allow(peer).to receive(:write).and_wrap_original do |original, bytes|
      result = original.call(bytes)
      raise IOError, 'synthetic transport failure' if peer.sent.last.payload_variant == :set_module_config

      result
    end
    result = backup_api.import(options)
    expect(result).to include(status: :partial_failure, readback_confirmed: 0, transaction: :open)
    expect(result[:failure]).to include(error: 'IOError')
    expect(peer.sent.map(&:payload_variant)).to eq(%i[begin_edit_settings set_module_config])
  end

  it 'does not infer fixed position from other getters when no supported getter exists' do
    peer.drop_ack_on = :set_fixed_position
    result = backup_api.import(options.merge(backup: Meshtastic::DeviceProfile.new(fixed_position: { latitude_i: 1 }).to_proto))
    expect(result).to include(status: :partial_failure, acknowledged: 0, readback_confirmed: 0, transaction: :open)
    expect(result[:failure]).to include(operation: :set_fixed_position, readback: :unsupported)
    expect(peer.sent.map(&:payload_variant)).to eq(%i[begin_edit_settings set_fixed_position])
  end

  it 'keeps commit uncertainty separate from successfully readback-confirmed sections' do
    peer.silent_on = :commit_edit_settings
    result = backup_api.import(options)
    expect(result).to include(status: :partial_failure, acknowledged: 1, readback_confirmed: 1, persistence_verified: false, transaction: :commit_uncertain)
    expect(result[:failure]).to include(operation: :commit_edit_settings, error: 'Timeout::Error')
    expect(peer.sent.map(&:payload_variant)).to eq(%i[begin_edit_settings set_module_config get_module_config_request set_config commit_edit_settings])
  end

  it 'does not recover a begin timeout by reading or writing any sections' do
    peer.silent_on = :begin_edit_settings
    result = backup_api.import(options)
    expect(result).to include(status: :partial_failure, attempted: 0, readback_confirmed: 0, transaction: :begin_uncertain)
    expect(peer.sent.map(&:payload_variant)).to eq([:begin_edit_settings])
  end

  it 'uses a fresh request ID and preserves stale, wrong-source, wrong-variant and late ACK packets' do
    unrelated = []
    allow(peer).to receive(:write).and_wrap_original do |original, bytes|
      result = original.call(bytes)
      if peer.sent.last.payload_variant == :get_module_config_request
        queue = peer.handle[:from_radio_queue]
        correct = queue.pop(true)
        stale = Meshtastic::FromRadio.decode(correct.to_proto)
        stale.packet.decoded.request_id = peer.packets[-2].id
        wrong_source = Meshtastic::FromRadio.decode(correct.to_proto)
        wrong_source.packet.from = 0x11223344
        wrong_variant = Meshtastic::FromRadio.decode(correct.to_proto)
        wrong_variant.packet.decoded.payload = Meshtastic::AdminMessage.new(get_owner_response: {}).to_proto
        late_ack = Meshtastic::FromRadio.new(packet: { from: correct.packet.from, decoded: { request_id: peer.packets[-2].id, portnum: :ROUTING_APP, payload: Meshtastic::Routing.new(error_reason: :NONE).to_proto } })
        unrelated.push(stale, wrong_source, wrong_variant, late_ack)
        unrelated.each { |packet| queue << packet }
        queue << correct
      end
      result
    end
    result = backup_api.import(options)
    expect(result).to include(status: :applied, acknowledged: 1, readback_confirmed: 1)
    expect(peer.packets.map(&:id).uniq.length).to eq(peer.packets.length)
    expect(Array.new(unrelated.length) { peer.handle[:from_radio_queue].pop(true) }).to eq(unrelated)
  end

  it 'does not accept incorrectly correlated matching values when no correct response arrives' do
    allow(peer).to receive(:write).and_wrap_original do |original, bytes|
      result = original.call(bytes)
      if peer.sent.last.payload_variant == :get_module_config_request
        packet = peer.handle[:from_radio_queue].pop(true)
        packet.packet.decoded.request_id = peer.packets[-2].id
        peer.handle[:from_radio_queue] << packet
      end
      result
    end
    result = backup_api.import(options)
    expect(result).to include(status: :partial_failure, readback_confirmed: 0, transaction: :open)
    expect(result[:failure]).to include(readback: :failed, error: 'Timeout::Error')
    expect(peer.handle[:from_radio_queue].length).to eq(1)
  end

  it 'uses the existing owner comparison excluding generated identity metadata' do
    peer.drop_ack_on = :set_owner
    allow(peer).to receive(:write).and_wrap_original do |original, bytes|
      result = original.call(bytes)
      if peer.sent.last.payload_variant == :set_owner
        peer.state[:owner].id = '!aabbccdd'
        peer.state[:owner].macaddr = 'generated'
      end
      result
    end
    result = backup_api.import(options.merge(backup: Meshtastic::DeviceProfile.new(long_name: 'Portable', is_unmessagable: false).to_proto, verify: true))
    expect(result).to include(status: :readback_matched, acknowledged: 0, readback_confirmed: 1, readback_matched: 1, persistence_verified: false)
    expect(result[:records].first).to include(status: :readback_confirmed, readback: :matched)
  end
end

describe 'Meshtastic::Admin::Backup DeviceProfile validation' do
  let(:backup_api) { Meshtastic::Admin::Backup }
  let(:peer) { BackupRadioPeer.new }

  it 'does not claim an absent optional owner flag readback matches an explicitly present false value' do
    allow(peer).to receive(:write).and_wrap_original do |original, bytes|
      result = original.call(bytes)
      peer.state[:owner].clear_is_unmessagable if peer.sent.last.payload_variant == :set_owner
      result
    end
    profile = Meshtastic::DeviceProfile.new(is_unmessagable: false)
    result = backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, verify: true, timeout: 0.3)
    expect(result).to include(status: :readback_incomplete, readback_matched: 0)
    expect(result[:records].first[:readback]).to eq(:mismatch)
  end

  it 'maps multiple URL channels and URL-only LoRa without manufacturing absent fields' do
    channels = Meshtastic::ChannelSet.new(settings: [{ psk: "\x01".b }, { psk: "\x00".b }], lora_config: { region: :US })
    profile = Meshtastic::DeviceProfile.new(channel_url: "https://meshtastic.org/d/##{Base64.urlsafe_encode64(channels.to_proto)}")
    result = backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, timeout: 0.3)
    expect(result[:plan]).to eq([{ section: 'channel', slot: 0 }, { section: 'channel', slot: 1 }, { section: 'config', slot: 'LORA_CONFIG' }])
    expect(peer.sent.take(2).map { |message| message.set_channel.role }).to eq(%i[PRIMARY SECONDARY])
    expect(peer.sent.last.set_config.lora).to eq(channels.lora_config)
  end

  it 'keeps ordinary profile writes in source plan order before disruptive sections' do
    modules = Meshtastic::ModuleConfig.descriptor.to_h { |field| [field.name.to_sym, {}] }
    profile = Meshtastic::DeviceProfile.new(long_name: 'order', ringtone: '', canned_messages: '', config: { device: {}, position: {}, power: {}, display: {}, lora: {}, security: {} }, module_config: modules)
    plan = backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, dry_run: true)[:plan]
    expect(plan.map { |entry| entry[:slot] || entry[:section] }).to eq(%w[owner ringtone canned_messages DEVICE_CONFIG POSITION_CONFIG POWER_CONFIG DISPLAY_CONFIG] + backup_api::MODULE_TYPES.map(&:to_s) + %w[LORA_CONFIG SECURITY_CONFIG])
    expect(peer.sent).to be_empty
  end

  it 'auto-detects binary content and cfg paths while retaining explicit and automatic JSON input' do
    profile = Meshtastic::DeviceProfile.new(long_name: 'x' * 123, is_unmessagable: false)
    Dir.mktmpdir do |directory|
      ['profile.cfg', 'profile.bin'].each do |name|
        path = File.join(directory, name)
        File.binwrite(path, profile.to_proto)
        expect(backup_api.import(transport_obj: peer.handle, path: path, dry_run: true)[:planned]).to eq(1)
      end
      expect(backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, dry_run: true)[:planned]).to eq(1)
      document = { 'format' => backup_api::FORMAT, 'version' => 1, 'warning' => '', 'records' => [] }
      %i[auto json].each do |format|
        expect(backup_api.import(transport_obj: peer.handle, backup: JSON.generate(document), format: format, dry_run: true)[:planned]).to eq(0)
        expect(backup_api.import(transport_obj: peer.handle, backup: document, format: format, dry_run: true)[:planned]).to eq(0)
      end
      expect { backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, format: :unknown, dry_run: true) }.to raise_error(ArgumentError)
      expect(peer.sent).to be_empty
    end
  end

  it 'rejects malformed, unknown, duplicate or empty binary profiles before all Admin requests' do
    valid = Meshtastic::DeviceProfile.new(long_name: 'synthetic').to_proto
    invalid = ['', 'arbitrary bytes', "\x0a\x05x".b, "\x58\x01".b, valid + "\x58\x01".b, valid + valid,
               "\x08\x01".b, "\x48\x02".b, "\x48\x80\x00".b, "\x22\x04\x0a\x02\x08\x7f".b,
               "\x22\x04\x0a\x02\xf8\x07".b, Meshtastic::DeviceProfile.new(config: { version: 24 }).to_proto,
               Meshtastic::DeviceProfile.new(config: { lora: { frequency_offset: Float::NAN } }).to_proto,
               "\x0a\x01\xff".b, "\x0a\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02".b,
               "\x22\x09\x0a\x07\x18\x80\x80\x80\x80\x80\x01".b]
    invalid.each do |bytes|
      expect { backup_api.import(transport_obj: peer.handle, backup: bytes, format: :device_profile, edit_transaction: true) }.to raise_error(ArgumentError)
      expect(peer.sent).to be_empty
    end
  end

  it 'validates the entire channel URL including wire fields and conflicts before any writes' do
    good = Meshtastic::ChannelSet.new(settings: [{ psk: "\x01".b }], lora_config: { region: :US })
    encode_url = ->(bytes) { "https://meshtastic.org/e/##{Base64.urlsafe_encode64(bytes, padding: false)}" }
    urls = ['not a URL', '', encode_url.call(''), encode_url.call(good.to_proto + "\x18\x01".b),
            encode_url.call(Meshtastic::ChannelSet.new(settings: [{ psk: 'invalid' }]).to_proto),
            encode_url.call(good.to_proto).sub('/e/', '/e/?add=true')]
    urls.each do |url|
      profile = Meshtastic::DeviceProfile.new(long_name: 'synthetic', channel_url: url)
      expect { backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, format: :device_profile, edit_transaction: true) }.to raise_error(ArgumentError)
      expect(peer.sent).to be_empty
    end
    profile = Meshtastic::DeviceProfile.new(config: { lora: { region: :UNSET } }, channel_url: encode_url.call(good.to_proto))
    expect { backup_api.import(transport_obj: peer.handle, backup: profile.to_proto, format: :device_profile) }.to raise_error(ArgumentError, /conflicting/)
    expect(peer.sent).to be_empty
  end
end

describe 'Meshtastic::Admin::Backup validation and readback' do
  let(:backup_api) { Meshtastic::Admin.const_get(:Backup) }
  let(:peer) { BackupRadioPeer.new }
  let(:options) { { transport_obj: peer.handle, config_types: [:DEVICE_CONFIG], module_config_types: [:MQTT_CONFIG], channel_indexes: [0], include_ui: true, timeout: 0.3 } }

  it 'rejects every malformed document before begin-edit, including unknown fields and conflicting oneofs' do
    document = backup_api.export(options)[:backup]
    mutations = [
      ->(d) { d['version'] = 2 }, ->(d) { d['version'] = 1.0 }, ->(d) { d['unknown'] = true },
      ->(d) { d['records'] << d['records'].first.dup },
      ->(d) { d['records'][0]['value']['id'] = '!aabbccdd' },
      ->(d) { d['records'][1]['value']['device']['unknown'] = true },
      ->(d) { d['records'][1]['value']['device']['serial_enabled'] = 'false' },
      ->(d) { d['records'][1]['value']['device']['button_gpio'] = -1 },
      ->(d) { d['records'][1]['value']['network'] = {} },
      ->(d) { d['records'][1]['value'] = {} },
      ->(d) { d['records'][1]['slot'] = 'SESSIONKEY_CONFIG' },
      ->(d) { d['records'][3]['value']['index'] = 2 },
      ->(d) { d['records'][3]['value']['settings']['psk'] = 'AP8' },
      ->(d) { d['records'][4]['value']['screen_lock'] = nil }
    ]
    peer.sent.clear
    mutations.each do |mutate|
      invalid = Marshal.load(Marshal.dump(document))
      mutate.call(invalid)
      expect { backup_api.import(transport_obj: peer.handle, backup: invalid, edit_transaction: true) }.to raise_error(ArgumentError)
      expect(peer.sent).to be_empty
    end
  end

  it 'rejects unsupported transports and invalid options before any requests' do
    expect { backup_api.export(transport_obj: MQTTClient.new) }.to raise_error(ArgumentError, /MQTT/)
    expect { backup_api.import(transport_obj: MQTTClient.new, backup: {}, dry_run: true) }.to raise_error(ArgumentError, /MQTT/)
    [{ config_types: [:SESSIONKEY_CONFIG] }, { module_config_types: [:BOGUS] }, { channel_indexes: [0, 0] },
     { channel_indexes: [8] }, { include_ui: 'false' }, { dry_run: true }, { session_passkey: 'secret!!' }].each do |invalid|
      expect { backup_api.export(options.merge(invalid)) }.to raise_error(ArgumentError)
    end
    expect(peer.sent).to be_empty
  end

  it 'optionally compares fresh readback while still refusing to claim durable persistence' do
    document = backup_api.export(options.merge(module_config_types: [], include_ui: false))[:backup]
    peer.sent.clear
    result = backup_api.import(transport_obj: peer.handle, backup: document, verify: true, timeout: 0.3)
    expect(result).to include(status: :readback_matched, readback_matched: 3, acknowledged: 3, persistence_verified: false)
    expect(peer.sent.map(&:payload_variant)).to eq(%i[set_owner set_config set_channel get_owner_request get_config_request get_channel_request])
  end

  it 'rejects wrong section responses rather than publishing a mislabeled backup' do
    peer.state[:device] = Meshtastic::Config.new(network: {})
    expect { backup_api.export(options) }.to raise_error(ArgumentError, /slot/)
  end

  it 'fails export on timeout without creating a partial backup file' do
    peer.silent_on = :get_config_request
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'incomplete.json')
      expect { backup_api.export(options.merge(path: path, timeout: 0.1)) }.to raise_error(Timeout::Error)
      expect(File.exist?(path)).to be(false)
    end
  end

  it 'preserves unrelated and incorrectly correlated packets while taking fresh reads' do
    unrelated = Meshtastic::FromRadio.new(packet: Meshtastic::MeshPacket.new(from: 0xaabbccdd, decoded: Meshtastic::Data.new(portnum: :ADMIN_APP, request_id: 1, payload: Meshtastic::AdminMessage.new(get_owner_response: { long_name: 'stale' }).to_proto)))
    peer.handle[:from_radio_queue] << unrelated
    result = backup_api.export(options)
    expect(result[:backup]['records'].first['value']['long_name']).to eq('Backup node')
    expect(peer.handle[:from_radio_queue].pop(true)).to eq(unrelated)
  end

  it 'reports readback timeouts without replaying writes or hiding successful ACKs' do
    document = backup_api.export(options.merge(module_config_types: [], include_ui: false))[:backup]
    peer.sent.clear
    peer.silent_on = :get_config_request
    result = backup_api.import(transport_obj: peer.handle, backup: document, verify: true, timeout: 0.1)
    expect(result).to include(status: :readback_incomplete, acknowledged: 3, readback_matched: 2)
    expect(result[:records][1]).to include(readback: :failed, readback_error: 'Timeout::Error')
    expect(peer.sent.count { |m| m.payload_variant == :set_config }).to eq(1)
  end

  it 'documents both public operations and secret limitations in help' do
    expect { backup_api.help }.to output(/Backup.export.*Backup.import.*format:.*:auto.*:json.*:device_profile.*dry_run.*edit_transaction.*verify/m).to_stdout
    expect(backup_api.authors).to include('0day')
  end

  it 'rejects duplicate JSON keys and malformed JSON without echoing file secrets' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'invalid.json')
      File.write(path, '{"version":2,"version":1,"secret":"sensitive-content"}')
      expect { backup_api.import(transport_obj: peer.handle, path: path) }.to raise_error(ArgumentError, /invalid backup JSON|duplicate/)
      File.write(path, '{"secret":"sensitive-content"')
      expect { backup_api.import(transport_obj: peer.handle, path: path) }.to raise_error(ArgumentError, 'invalid backup JSON') do |error|
        expect(error.full_message).not_to include('sensitive-content')
      end
      expect(peer.sent).to be_empty
    end
  end

  it 'round-trips every supported core and module selector with protobuf defaults' do
    configs = Meshtastic::Config.descriptor.to_a.take(8).map do |field|
      message = Meshtastic::Config.new(field.name.to_sym => {})
      peer.state[field.name.to_sym] = message
      message
    end
    modules = Meshtastic::ModuleConfig.descriptor.to_a.map.with_index do |field, index|
      message = Meshtastic::ModuleConfig.new(field.name.to_sym => {})
      peer.state[backup_api::MODULE_TYPES[index]] = message
      message
    end
    document = backup_api.export(options.merge(config_types: backup_api::CONFIG_TYPES, module_config_types: backup_api::MODULE_TYPES, include_owner: false, include_ui: false, channel_indexes: []))[:backup]
    peer.sent.clear
    result = backup_api.import(transport_obj: peer.handle, backup: document, timeout: 0.3)
    expect(result[:acknowledged]).to eq(configs.length + modules.length)
    restored = peer.sent.map { |message| message.public_send(message.payload_variant) }
    expect(restored).to match_array(configs + modules)
  end

  it 'exports fresh correlated section protobuf JSON without owner identity or session passkeys' do
    result = backup_api.export(options)
    expect(result[:status]).to eq(:exported)
    expect(result[:count]).to eq(5)
    document = result[:backup]
    expect(document).to include('format' => 'meshtastic-admin-backup', 'version' => 1)
    text = JSON.generate(document)
    expect(text).not_to include('passkey!', 'aabbccdd', 'macaddr', 'hw_model')
    expect(text).to include('AP8=', 'serial_enabled', 'broker-secret')
    expect(peer.sent.map(&:payload_variant)).to eq(%i[get_owner_request get_config_request get_module_config_request get_channel_request get_ui_config_request])
    expect(peer.sent.find { |msg| msg.payload_variant == :get_channel_request }.get_channel_request).to eq(1)
  end
end
