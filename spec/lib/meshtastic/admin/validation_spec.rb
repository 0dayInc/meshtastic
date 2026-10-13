# frozen_string_literal: true

require 'spec_helper'

describe 'Admin semantic validation' do
  it 'rejects owner names beyond the pinned firmware UTF-8 byte limit without truncating' do
    name = 'é' * 13
    user = Meshtastic::User.new(long_name: name)
    expect { Meshtastic::Admin.encode(set_owner: user) }.to raise_error(ArgumentError, /24/)
    expect(user.long_name).to eq(name)
    expect(Meshtastic::Admin.encode(set_owner: Meshtastic::User.new(long_name: 'é' * 12)).set_owner.long_name.bytesize).to eq(24)
  end

  it 'rejects names firmware cannot represent, while preserving omitted names' do
    [{ long_name: "bad\0name" }, { long_name: " \t" }, { short_name: 'ééé' }].each do |fields|
      expect { Meshtastic::Admin.encode(set_owner: Meshtastic::User.new(fields)) }.to raise_error(ArgumentError)
    end
    expect { Meshtastic::Admin.encode(set_owner: Meshtastic::User.new) }.not_to raise_error
  end

  it 'validates ham nanopb fields and the composed owner name before encoding' do
    [{ call_sign: '' }, { call_sign: '        ' }, { call_sign: 'ABCDEFGH' },
     { call_sign: 'N0CALL', long_name: 'é' * 8 }, { call_sign: 'N0CALL', short_name: 'ABCDE' }].each do |fields|
      expect { Meshtastic::Admin.encode(set_ham_mode: Meshtastic::HamParameters.new(fields)) }.to raise_error(ArgumentError)
    end
    expect { Meshtastic::Admin.encode(set_ham_mode: Meshtastic::HamParameters.new(call_sign: 'N0CALL', long_name: 'é' * 7)) }.not_to raise_error
  end

  it 'rejects unknown enum integers recursively and accepts known numeric enum values' do
    [Meshtastic::AdminMessage.new(get_config_request: 999),
     Meshtastic::AdminMessage.new(set_config: { lora: { region: 999 } }),
     Meshtastic::AdminMessage.new(set_module_config: { serial: { mode: 999 } })].each do |message|
      expect { Meshtastic::Admin.encode(message: message) }.to raise_error(ArgumentError, /enum/)
    end
    expect { Meshtastic::Admin.encode(get_config_request: 0) }.not_to raise_error
  end

  it 'requires a selected writable config section but allows an explicitly selected default section' do
    [Meshtastic::AdminMessage.new(set_config: Meshtastic::Config.new),
     Meshtastic::AdminMessage.new(set_module_config: Meshtastic::ModuleConfig.new),
     Meshtastic::AdminMessage.new(set_config: { sessionkey: {} }),
     Meshtastic::AdminMessage.new(set_config: { device_ui: {} })].each do |message|
      expect { Meshtastic::Admin.encode(message: message) }.to raise_error(ArgumentError, /section|sessionkey|device_ui/)
    end
    expect { Meshtastic::Admin.encode(set_config: Meshtastic::Config.new(device: {})) }.not_to raise_error
  end

  it 'applies channel PSK, name, index and role validation to raw Admin writes' do
    [{ index: 8 }, { index: -1 }, { role: 99 }, { settings: { psk: 'bad' } },
     { settings: { name: 'é' * 6 } }, { settings: { name: "x\0y" } }].each do |fields|
      expect { Meshtastic::Admin.encode(set_channel: Meshtastic::Channel.new(fields)) }.to raise_error(ArgumentError)
    end
    [0, 1, 16, 32].each do |length|
      channel = Meshtastic::Channel.new(index: 7, role: :PRIMARY, settings: { name: 'é' * 5, psk: 'x' * length })
      expect(Meshtastic::Admin.encode(set_channel: channel).set_channel).to eq(channel)
    end
  end

  it 'preflights every URL section and rejects invalid offline settings before any write' do
    expect(Meshtastic::Admin).not_to receive(:send)
    expect { Meshtastic::Admin::Channel.build_settings(name: "x\0y") }.to raise_error(ArgumentError)
    set = Meshtastic::ChannelSet.new(settings: [{ psk: 'x' }], lora_config: { region: 999 })
    url = "https://meshtastic.org/e/##{Base64.urlsafe_encode64(set.to_proto, padding: false)}"
    expect { Meshtastic::Admin::Channel.apply_url(url: url, transport_obj: { serial_conn: Object.new }) }.to raise_error(ArgumentError)
  end

  it 'rejects malformed security key sizes rather than silently triggering firmware identity preservation' do
    [{ private_key: 'bad' }, { public_key: 'bad' }, { admin_key: ['bad'] }].each do |fields|
      expect { Meshtastic::Admin.encode(set_config: Meshtastic::Config.new(security: fields)) }.to raise_error(ArgumentError, /key/)
    end
    expect { Meshtastic::Admin.encode(set_config: Meshtastic::Config.new(security: { private_key: 'k' * 32 })) }.not_to raise_error
  end

  it 'rejects invalid mutations before delivery or remote session acquisition across public setters' do
    handle = { serial_conn: Object.new, my_node_num: 0xaabbccdd, from_radio_queue: Queue.new }
    transport = { transport_obj: handle, to: '!aabbccee' }
    expect(Meshtastic).not_to receive(:deliver_data)
    [[:set_owner, { long_name: 'x' * 25 }], [:set_ham_mode, { call_sign: '' }],
     [:set_channel, { channel_settings: Meshtastic::Channel.new(index: 8) }],
     [:set_config, { config: Meshtastic::Config.new }],
     [:set_module_config, { module_config: Meshtastic::ModuleConfig.new }]].each do |method, payload|
      expect { Meshtastic::Admin.public_send(method, transport.merge(payload)) }.to raise_error(ArgumentError)
    end
    expect { Meshtastic::Admin::Config.set_lora(transport.merge(lora: { region: 999 })) }.to raise_error(ArgumentError)
    expect { Meshtastic::ModuleConfig.set(transport.merge(module_config: Meshtastic::ModuleConfig.new)) }.to raise_error(ArgumentError)
    expect { Meshtastic::Admin::Channel.set(transport.merge(settings: { psk: 'bad' })) }.to raise_error(ArgumentError)
    expect(handle).not_to have_key(:admin_sessions)
  end
end
