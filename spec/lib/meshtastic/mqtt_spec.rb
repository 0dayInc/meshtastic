# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/payload_fixtures'

describe Meshtastic::MQTT do # rubocop:disable Metrics/BlockLength
  include PayloadFixtures

  it 'decodes every fixture from already decoded and AES encrypted ServiceEnvelopes without losing subsequent packets' do
    [false, true].each do |encrypted|
      client = fake_mqtt_obj
      payload_cases.each do |port, bytes, _expected|
        packet = payload_radio(port, bytes).packet
        if encrypted
          cipher = OpenSSL::Cipher.new('AES-128-CTR')
          cipher.encrypt
          cipher.key = Base64.strict_decode64('1PG7OiApB1nwvP+rz05pAQ==')
          cipher.iv = [42, 0, 123, 0].pack('V4')
          data = packet.decoded.to_proto
          packet.encrypted = (data.empty? ? ''.b : cipher.update(data)) + cipher.final
        end
        envelope = Meshtastic::ServiceEnvelope.new(packet: packet, channel_id: 'LongFast')
        client.incoming << mqtt_packet(topic: 'msh/US/2/e/LongFast/!0000007b', payload: envelope.to_proto)
      end
      client.incoming << nil
      received = []
      described_class.subscribe(mqtt_obj: client) { |message| received << message.dig(:packet, :decoded, :payload) }
      expect(received).to eq(payload_cases.map(&:last))
    end
  end

  def fake_mqtt_obj(client_id: '00000b0b')
    published = []
    subscribed = []
    incoming = Queue.new
    client = Object.new
    client.define_singleton_method(:client_id) { client_id }
    client.define_singleton_method(:published) { published }
    client.define_singleton_method(:subscribed) { subscribed }
    client.define_singleton_method(:incoming) { incoming }
    client.define_singleton_method(:subscribe) do |topic, qos|
      subscribed << { topic: topic, qos: qos }
    end
    client.define_singleton_method(:publish) do |topic, payload|
      published << { topic: topic, payload: payload }
      payload.bytesize
    end
    client.define_singleton_method(:get_packet) do |&block|
      loop do
        packet = incoming.pop
        break if packet.nil?

        block.call(packet)
      end
    end
    client.define_singleton_method(:disconnect) { @disconnected = true }
    client.define_singleton_method(:disconnected?) { @disconnected == true }
    client
  end

  def mqtt_packet(topic:, payload:)
    packet = Object.new
    packet.define_singleton_method(:topic) { topic }
    packet.define_singleton_method(:payload) { payload }
    packet.define_singleton_method(:to_s) { payload.to_s }
    packet
  end

  def publish_and_subscribe(opts = {})
    mqtt_obj = fake_mqtt_obj
    described_class.send_text({ mqtt_obj: mqtt_obj }.merge(opts))
    published = mqtt_obj.published.last
    mqtt_obj.incoming << mqtt_packet(topic: published[:topic], payload: published[:payload])
    mqtt_obj.incoming << nil
    received = nil
    described_class.subscribe({ mqtt_obj: mqtt_obj }.merge(opts)) do |message|
      received = message
      break
    end
    [mqtt_obj, received]
  end

  describe '.connect' do
    it 'configures keep_alive and ack_timeout on the MQTT client' do
      client = instance_double(MQTT::Client, keep_alive: 15, ack_timeout: 30)
      allow(client).to receive(:keep_alive=)
      allow(client).to receive(:ack_timeout=)
      expect(MQTTClient).to receive(:connect).with(
        hash_including(host: 'localhost', port: 1883, ssl: false, username: 'meshdev', client_id: 'abcd1234')
      ).and_return(client)

      described_class.connect(host: 'localhost', client_id: 'abcd1234', keep_alive: 15, ack_timeout: 30)
      expect(client).to have_received(:keep_alive=).with(15)
      expect(client).to have_received(:ack_timeout=).with(30)
    end
  end

  describe '.send_text' do
    it 'publishes an encrypted ServiceEnvelope without UART framing' do
      mqtt_obj = fake_mqtt_obj
      described_class.send_text(
        mqtt_obj: mqtt_obj,
        from: '!00000b0b',
        to: '!ffffffff',
        channel: 0,
        text: 'ping',
        psks: { LongFast: 'AQ==' }
      )
      published = mqtt_obj.published.last
      expect(published[:topic]).to eq('msh/US/2/e/LongFast/!00000b0b')
      expect(published[:payload].getbyte(0)).not_to eq(Meshtastic::START1)
      envelope = Meshtastic::ServiceEnvelope.decode(published[:payload])
      expect(envelope.channel_id).to eq('LongFast')
      expect(envelope.packet.decoded.to_s).to eq('')
      expect(envelope.packet.encrypted.to_s).not_to eq('')
      expect(envelope.packet.to).to eq(0xffffffff)
      expect(envelope.packet.from).to eq(0xb0b)
    end

    it 'rejects text exceeding the byte limit without publishing' do
      mqtt_obj = fake_mqtt_obj
      expect do
        described_class.send_text(
          mqtt_obj: mqtt_obj,
          text: 'é' * Meshtastic::Constants::DATA_PAYLOAD_LEN
        )
      end.to raise_error(ArgumentError, /Bytes/)
      expect(mqtt_obj.published).to be_empty
    end
  end

  describe 'mqtt reception' do
    it 'does not apply a channel PSK to PKI ciphertext or fall back for an unknown channel' do
      [true, false].each do |pki|
        client = fake_mqtt_obj
        packet = Meshtastic::MeshPacket.new(id: 42, from: 123, encrypted: 'ciphertext', pki_encrypted: pki)
        envelope = Meshtastic::ServiceEnvelope.new(packet: packet, channel_id: 'Other')
        client.incoming << mqtt_packet(topic: 'msh/US/2/e/Other/!0000007b', payload: envelope.to_proto)
        client.incoming << nil
        received = []
        expect(OpenSSL::Cipher).not_to receive(:new)
        described_class.subscribe(mqtt_obj: client) { |message| received << message }
        expect(received.first.dig(:packet, :encrypted)).to eq('ciphertext')
        expect(received.first.dig(:packet, :decoded)).to be_nil
        expect(received.first.dig(:packet, :decryption_error)).to match(/PKI|No PSK/)
      end
    end

    it 'does not substitute radio hash selection when MQTT channel identity is missing' do
      client = fake_mqtt_obj
      key = Base64.strict_decode64('1PG7OiApB1nwvP+rz05pAQ==')
      hash = ('LongFast'.bytes + key.bytes).reduce(0, :^)
      envelope = Meshtastic::ServiceEnvelope.new(packet: Meshtastic::MeshPacket.new(channel: hash, encrypted: 'ciphertext'))
      client.incoming << mqtt_packet(topic: '', payload: envelope.to_proto)
      client.incoming << nil
      expect(OpenSSL::Cipher).not_to receive(:new)
      described_class.subscribe(mqtt_obj: client) do |message|
        expect(message.dig(:packet, :encrypted)).to eq('ciphertext')
        expect(message.dig(:packet, :decryption_error)).to match(/No PSK/)
      end
    end

    it 'decrypts a published text message as UTF-8, never as a nested protobuf' do
      text = "\n\x02hi"
      _mqtt_obj, received = publish_and_subscribe(text: text, from: '!00000b0b', psks: { LongFast: 'AQ==' })
      expect(received.dig(:packet, :decoded, :payload)).to eq(text)
      expect(received.dig(:packet, :decoded, :payload).encoding).to eq(Encoding::UTF_8)
      expect(received.dig(:packet, :node_id_from)).to eq('!b0b')
    end

    it 'yields received text through subscription filters' do
      mqtt_obj = fake_mqtt_obj
      %w[hidden hello].each do |text|
        described_class.send_text(mqtt_obj: mqtt_obj, text: text, from: '!00000b0b', psks: { LongFast: 'AQ==' })
      end
      mqtt_obj.published.each do |item|
        mqtt_obj.incoming << mqtt_packet(topic: item[:topic], payload: item[:payload])
      end
      mqtt_obj.incoming << nil
      received = []
      described_class.subscribe(mqtt_obj: mqtt_obj, include: 'TEXT_MESSAGE_APP', exclude: 'hidden') do |message|
        received << message.dig(:packet, :decoded, :payload)
      end
      expect(received).to eq(['hello'])
    end

    it 'subscribes to the assembled root/region/topic path' do
      mqtt_obj = fake_mqtt_obj
      mqtt_obj.incoming << nil
      described_class.subscribe(mqtt_obj: mqtt_obj, root_topic: 'msh', region: 'US', topic: '2/e/LongFast/#', qos: 1)
      expect(mqtt_obj.subscribed).to eq([{ topic: 'msh/US/2/e/LongFast/#', qos: 1 }])
    end

    it 'includes the raw MQTT packet when requested' do
      mqtt_obj, received = publish_and_subscribe(text: 'hello', from: '!00000b0b', include_raw: true)
      expect(Meshtastic::ServiceEnvelope.decode(received.dig(:packet, :raw_packet)).packet.from).to eq(0xb0b)
      expect(mqtt_obj.disconnected?).to be(true)
    end

    it 'requires psks to be a hash of channel keys' do
      mqtt_obj = fake_mqtt_obj
      expect do
        described_class.subscribe(mqtt_obj: mqtt_obj, psks: 'AQ==')
      end.to raise_error(/psks parameter must be a hash/)
    end
  end

  describe '.disconnect' do
    it 'returns nil and disconnects the MQTT client' do
      mqtt_obj = fake_mqtt_obj
      expect(described_class.disconnect(mqtt_obj: mqtt_obj)).to be_nil
      expect(mqtt_obj.disconnected?).to be(true)
    end
  end

  describe '.help' do
    it 'prints usage without raising' do
      expect { described_class.help }.to output(/USAGE/).to_stdout
    end
  end
end
