# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Meshtastic::Admin::Channel do
  it 'documents transport_obj rather than legacy connection keywords' do
    expect { described_class.help }.to output(/transport_obj:/).to_stdout
    expect { described_class.help }.not_to output(/serial_obj:|bluetooth_obj:|tcp_obj:|mqtt_obj:/).to_stdout
  end
end

shared_context 'channel serial framing' do
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
    Meshtastic::AdminMessage.decode(Meshtastic::ToRadio.decode(body).packet.decoded.payload)
  end
end

describe Meshtastic::Admin::Channel do
  include_context 'channel serial framing'

  it 'rejects legacy connection keys before filtering or building channel options' do
    %i[serial_obj bluetooth_obj tcp_obj mqtt_obj].each do |key|
      expect { described_class.set(transport_obj: fake_serial_obj, key => nil, index: -1) }
        .to raise_error(ArgumentError, /#{key}.*transport_obj/)
    end
  end

  it 'requests a channel by index via Admin' do
    serial_obj = fake_serial_obj
    described_class.get(transport_obj: serial_obj, index: 1)
    expect(decode_admin(serial_obj).get_channel_request).to eq(2)
  end

  [0, 7].each do |index|
    it "requests zero-based slot #{index} with its one-based wire index" do
      serial_obj = fake_serial_obj
      described_class.get(transport_obj: serial_obj, index: index)
      expect(decode_admin(serial_obj).get_channel_request).to eq(index + 1)
    end
  end

  it 'sets a Channel protobuf including settings and role' do
    serial_obj = fake_serial_obj
    settings = described_class.build_settings(name: 'LongFast', uplink_enabled: true)
    described_class.set(transport_obj: serial_obj, index: 0, role: :PRIMARY, settings: settings)
    channel = decode_admin(serial_obj).set_channel
    expect(channel.index).to eq(0)
    expect(channel.role).to eq(:PRIMARY)
    expect(channel.settings.name).to eq('LongFast')
    expect(channel.settings.uplink_enabled).to be true
  end

  it 'copies an existing channel and preserves settings when changing its role' do
    original = Meshtastic::Channel.new(index: 2, role: :SECONDARY, settings: { name: 'test', psk: "\x01".b })
    updated = described_class.build(channel: original, role: :DISABLED)
    expect(updated.settings).to eq(original.settings)
    expect(original.role).to eq(:SECONDARY)
    expect(updated).not_to equal(original)
  end

  it 'builds all settings including nested hashes without mutating existing settings' do
    original = Meshtastic::ChannelSettings.new(name: 'before', uplink_enabled: true)
    settings = described_class.build_settings(settings: original, name: 'after', psk: "\x01".b, channel_num: 3,
                                              id: 17, uplink_enabled: false, downlink_enabled: true,
                                              use_aead: true, module_settings: { position_precision: 13 })
    expect(settings.to_h).to include(name: 'after', psk: "\x01".b, channel_num: 3, id: 17,
                                     downlink_enabled: true, use_aead: true)
    expect(settings.uplink_enabled).to be false
    expect(settings.module_settings.position_precision).to eq(13)
    expect(original.name).to eq('before')
    expect(original.uplink_enabled).to be true
  end
end

describe Meshtastic::Admin::Channel, 'channel URL support' do
  include_context 'channel serial framing'

  it 'exports primary first and enabled secondary settings with LoRa in a channel URL' do
    primary = Meshtastic::Channel.new(index: 0, role: :PRIMARY, settings: { name: 'main', psk: "\x01".b })
    secondary = Meshtastic::Channel.new(index: 2, role: :SECONDARY, settings: { name: 'other' })
    disabled = Meshtastic::Channel.new(index: 3, settings: { name: 'hidden' })
    lora = Meshtastic::Config::LoRaConfig.new(region: :US, use_preset: true)
    url = described_class.export_url(channels: [secondary, disabled, primary], lora_config: lora)
    expect(url).to start_with('https://meshtastic.org/e/#')
    require 'base64'
    channel_set = Meshtastic::ChannelSet.decode(Base64.urlsafe_decode64(url.split('#').last))
    expect(channel_set.settings.map(&:name)).to eq(%w[main other])
    expect(channel_set.lora_config).to eq(lora)
    expect(url).not_to end_with('=')
  end

  it 'imports official e and legacy d URLs as offline ChannelSet protobufs' do
    expected = Meshtastic::ChannelSet.new(settings: [{ name: 'test', psk: "\x01".b }], lora_config: { region: :US })
    encoded = Base64.urlsafe_encode64(expected.to_proto, padding: false)
    %w[e d].each do |path|
      expect(described_class.import_url(url: "https://meshtastic.org/#{path}/##{encoded}")).to eq(expected)
    end
  end

  it 'rejects invalid URL envelopes and empty or oversized channel sets without leaking the URL' do
    empty = Base64.urlsafe_encode64(Meshtastic::ChannelSet.new.to_proto, padding: false)
    oversized = Base64.urlsafe_encode64(Meshtastic::ChannelSet.new(settings: Array.new(9) { { name: 'test' } }).to_proto, padding: false)
    valid = Base64.urlsafe_encode64(Meshtastic::ChannelSet.new(settings: [{ name: 'test' }]).to_proto, padding: false)
    urls = ["https://example.org/e/##{valid}", "https://meshtastic.org/v/##{valid}",
            'https://meshtastic.org/e/', 'https://meshtastic.org/e/#not!base64',
            'https://meshtastic.org/e/#_w', "https://meshtastic.org/e/##{empty}",
            "https://meshtastic.org/e/##{oversized}", "https://user:secret@meshtastic.org/e/##{valid}"]
    urls.each do |url|
      expect { described_class.import_url(url: url) }.to raise_error(ArgumentError, 'invalid channel URL')
    end
  end

  it 'exports only primary when include_all is false and requires exactly one primary' do
    primary = Meshtastic::Channel.new(role: :PRIMARY, settings: { name: 'main' })
    secondary = Meshtastic::Channel.new(index: 1, role: :SECONDARY, settings: { name: 'other' })
    url = described_class.export_url(channels: [primary, secondary], include_all: false)
    expect(described_class.import_url(url: url).settings.map(&:name)).to eq(['main'])
    [[], [secondary], [primary, primary]].each do |channels|
      expect { described_class.export_url(channels: channels) }.to raise_error(ArgumentError)
    end
  end

  it 'rejects invalid settings lengths and slot indexes before any write' do
    [-1, 8, 0.5, 'junk'].each do |index|
      serial_obj = fake_serial_obj
      expect { described_class.set(transport_obj: serial_obj, index: index, role: :PRIMARY) }.to raise_error(ArgumentError)
      expect(serial_obj[:written]).to be_empty
    end
    expect { described_class.build_settings(psk: 'bad') }.to raise_error(ArgumentError)
    expect { described_class.build_settings(name: 'a' * 12) }.to raise_error(ArgumentError)
    [0, 1, 16, 32].each do |length|
      expect(described_class.build_settings(psk: 'x' * length).psk.bytesize).to eq(length)
    end
  end

  it 'validates and overlays supplied channel/settings before transmission' do
    serial_obj = fake_serial_obj
    original = Meshtastic::Channel.new(index: 2, role: :SECONDARY, settings: { name: 'before', uplink_enabled: true })
    described_class.set(transport_obj: serial_obj, channel: original, name: 'after', uplink_enabled: false)
    written = decode_admin(serial_obj).set_channel
    expect(written.index).to eq(2)
    expect(written.settings.name).to eq('after')
    expect(written.settings.uplink_enabled).to be false
    expect(original.settings.name).to eq('before')
    expect(described_class.build(settings: { name: 'hash' }).settings.name).to eq('hash')
    invalid = Meshtastic::Channel.new(index: 8)
    expect { described_class.set(transport_obj: fake_serial_obj, channel: invalid) }.to raise_error(ArgumentError)
    expect { described_class.build(settings: { psk: 'bad' }) }.to raise_error(ArgumentError)
  end

  it 'applies an imported URL as indexed channel writes followed by its LoRa section' do
    serial_obj = fake_serial_obj
    channel_set = Meshtastic::ChannelSet.new(settings: [{ name: 'main' }, { name: 'other' }], lora_config: { region: :US })
    url = "https://meshtastic.org/e/##{Base64.urlsafe_encode64(channel_set.to_proto, padding: false)}"
    results = described_class.apply_url(transport_obj: serial_obj, url: url, session_passkey: 'test-key')
    frames = serial_obj[:written].dup
    messages = []
    until frames.empty?
      length = (frames.getbyte(2) << 8) + frames.getbyte(3)
      packet = Meshtastic::ToRadio.decode(frames.byteslice(4, length)).packet
      messages << Meshtastic::AdminMessage.decode(packet.decoded.payload)
      frames = frames.byteslice((length + 4)..)
    end
    expect(results.length).to eq(3)
    expect(messages.map(&:payload_variant)).to eq(%i[set_channel set_channel set_config])
    expect(messages.first.set_channel.index).to eq(0)
    expect(messages.first.set_channel.role).to eq(:PRIMARY)
    expect(messages[1].set_channel.index).to eq(1)
    expect(messages[1].set_channel.role).to eq(:SECONDARY)
    expect(messages.last.set_config.lora.region).to eq(:US)
    expect(messages.map(&:session_passkey)).to all(eq('test-key'))
  end

  it 'preflights all URL settings and refuses add-only links before writing' do
    serial_obj = fake_serial_obj
    invalid = Meshtastic::ChannelSet.new(settings: [{ name: 'good' }, { psk: 'bad' }])
    url = "https://meshtastic.org/e/##{Base64.urlsafe_encode64(invalid.to_proto, padding: false)}"
    expect { described_class.apply_url(transport_obj: serial_obj, url: url) }.to raise_error(ArgumentError)
    expect(serial_obj[:written]).to be_empty
    valid = Meshtastic::ChannelSet.new(settings: [{ name: 'test' }])
    url = "https://meshtastic.org/e/?add=true##{Base64.urlsafe_encode64(valid.to_proto, padding: false)}"
    expect { described_class.apply_url(transport_obj: serial_obj, url: url) }.to raise_error(ArgumentError, /add-only/)
    expect(serial_obj[:written]).to be_empty
  end

  it 'rejects unsupported channel roles before writing' do
    expect { described_class.build(role: 99) }.to raise_error(ArgumentError)
  end

  it 'rejects oversized or invalid enabled channel sets on export' do
    primary = Meshtastic::Channel.new(role: :PRIMARY, settings: { name: 'main' })
    secondary = Meshtastic::Channel.new(role: :SECONDARY, settings: { name: 'other' })
    expect { described_class.export_url(channels: [primary] + Array.new(8, secondary)) }.to raise_error(ArgumentError)
    primary.settings.psk = 'bad'
    expect { described_class.export_url(channels: [primary]) }.to raise_error(ArgumentError)
  end

  it 'prints usage without raising' do
    expect { described_class.help }.to output(/USAGE/).to_stdout
  end
end
