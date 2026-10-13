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
          packet.channel = ('LongFast'.bytes + Base64.strict_decode64('1PG7OiApB1nwvP+rz05pAQ==').bytes).reduce(0, :^)
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
    it 'fails closed on direct text and explicit PKI without publishing' do
      client = fake_mqtt_obj
      [{ to: '!00000002' }, { pki_encrypted: true, public_key: 'k' * 32 }].each do |options|
        expect { described_class.send_text({ mqtt_obj: client, text: 'private' }.merge(options)) }.to raise_error(ArgumentError, /PKI|direct/i)
      end
      expect(client.published).to be_empty
    end

    it 'selects the explicit channel key and firmware hash, never the first key' do
      client = fake_mqtt_obj
      keys = { Wrong: Base64.strict_encode64('w' * 16), Custom: Base64.strict_encode64('k' * 32) }
      described_class.send_text(mqtt_obj: client, channel_id: 'Custom', psks: keys, text: 'selected')
      item = client.published.last
      envelope = Meshtastic::ServiceEnvelope.decode(item[:payload])
      expect(envelope.channel_id).to eq('Custom')
      expect(envelope.packet.channel).to eq(('Custom'.bytes + ('k' * 32).bytes).reduce(0, :^))
      expect(item[:topic]).to include('/Custom/')
      client.incoming << mqtt_packet(topic: item[:topic], payload: item[:payload])
      client.incoming << nil
      described_class.subscribe(mqtt_obj: client, psks: keys) do |message|
        expect(message.dig(:packet, :decoded, :payload)).to eq('selected')
      end
      expect { described_class.send_text(mqtt_obj: client, psks: keys) }.to raise_error(ArgumentError, /channel_id|ambiguous/)
    end

    it 'encrypts and decrypts firmware CCM vectors for both AES key sizes over the broker codec' do
      # Firmware 8e6a88d CryptoEngine: L=2, M=12, nonce=id64le/from32le/00, AAD=from32le/to32le.
      # Independently generated using CBC-MAC/CTR, checked against upstream RFC3610 vector 1.
      { 16 => 'f0285b86af98b3f88815b9938ecf0ddf1693c987', 32 => '8640f69cc0583046e446be6d72147811991099bb' }.each do |size, vector|
        client = fake_mqtt_obj
        keys = { Custom: { psk: Base64.strict_encode64('k' * size), use_aead: true } }
        described_class.send_text(mqtt_obj: client, from: 123, last_packet_id: 41, channel_id: 'Custom', psks: keys, text: 'test')
        item = client.published.last
        packet = Meshtastic::ServiceEnvelope.decode(item[:payload]).packet
        expect(packet.encrypted.unpack1('H*')).to eq(vector)
        expect(packet.channel).to eq(('Custom'.bytes + ('k' * size).bytes).reduce(0, :^) ^ 0xae)
        client.incoming << mqtt_packet(topic: item[:topic], payload: item[:payload])
        client.incoming << nil
        described_class.subscribe(mqtt_obj: client, psks: keys) do |message|
          expect(message.dig(:packet, :decoded, :payload)).to eq('test')
          expect(message.dig(:packet, :security_provenance, :channel_authentication)).to eq(:aead)
          expect(message.dig(:packet, :security_provenance, :verification)).to eq(:untrusted)
        end
      end
    end

    it 'rejects conflicting channel selections and unsupported crypto requests before publishing' do
      client = fake_mqtt_obj
      cases = [
        { psks: { Custom: 'AQ==', 'Custom' => 'Ag==' }, channel_id: 'Custom' },
        { psks: { Custom: 'AQ==' }, channel_id: 'Unknown' },
        { psks: { Custom: 'AQ==' }, channel_id: 'Custom', topic: '2/e/Other/#' },
        { psks: nil }, { psks: {} }, { public_key: 'k' * 32 }
      ]
      cases.each do |options|
        expect { described_class.send_text({ mqtt_obj: client }.merge(options)) }.to raise_error(ArgumentError)
      end
      expect(client.published).to be_empty
    end

    it 'rejects misplaced mode options instead of silently publishing legacy CTR' do
      client = fake_mqtt_obj
      expect { described_class.send_text(mqtt_obj: client, use_aead: true, text: 'private') }.to raise_error(ArgumentError, /use_aead.*psks/)
      expect { described_class.send_data(mqtt_obj: client, use_aead: true, data: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP)) }.to raise_error(ArgumentError, /use_aead.*psks/)
      expect(client.published).to be_empty
      client.incoming << nil
      expect { described_class.subscribe(mqtt_obj: client, use_aead: true) }.to raise_error(ArgumentError, /use_aead.*psks/)
    end

    it 'requires an explicit boolean mode in structured key records' do
      client = fake_mqtt_obj
      [{ psk: 'AQ==' }, { psk: 'AQ==', use_aed: true }, { psk: 'AQ==', use_aead: 'true' }].each do |record|
        expect { described_class.send_text(mqtt_obj: client, psks: { Private: record }) }.to raise_error(ArgumentError)
      end
      expect(client.published).to be_empty
    end

    it 'accepts frozen key configuration without modifying caller options' do
      keys = { LongFast: 'AQ==' }.freeze
      client = fake_mqtt_obj
      options = { mqtt_obj: client, psks: keys, text: 'immutable' }.freeze
      described_class.send_text(options)
      client.incoming << nil
      described_class.subscribe(mqtt_obj: client, psks: keys)
      expect(keys).to eq(LongFast: 'AQ==')
      expect(options.keys).to eq(%i[mqtt_obj psks text])
    end

    it 'expands firmware short PSK aliases on any named channel' do
      client = fake_mqtt_obj
      described_class.send_text(mqtt_obj: client, channel_id: 'Custom', psks: { Custom: { psk: 'Ag==', use_aead: true } }, text: 'alias')
      packet = Meshtastic::ServiceEnvelope.decode(client.published.last[:payload]).packet
      key = Base64.strict_decode64('1PG7OiApB1nwvP+rz05pAQ==')
      key.setbyte(15, 2)
      expect(packet.channel).to eq(('Custom'.bytes + key.bytes).reduce(0, :^) ^ 0xae)
    end

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
    it 'rejects authenticated packet tampering, truncated tags and mode downgrades without plaintext' do
      vector = ['f0285b86af98b3f88815b9938ecf0ddf1693c987'].pack('H*')
      base = { from: 123, to: 0xffffffff, id: 42, channel: 'Custom'.bytes.reduce(0, :^) ^ 0xae, encrypted: vector }
      variants = vector.bytes.each_index.map do |index|
        altered = vector.dup
        altered.setbyte(index, altered.getbyte(index) ^ 1)
        base.merge(encrypted: altered)
      end
      variants += %i[from to id channel].map { |field| base.merge(field => base[field] ^ 1) }
      variants += [base.merge(encrypted: vector[0, 12])]
      [true, false].each do |aead|
        client = fake_mqtt_obj
        packets = aead ? variants : [base]
        packets.each do |fields|
          envelope = Meshtastic::ServiceEnvelope.new(packet: Meshtastic::MeshPacket.new(fields), channel_id: 'Custom')
          client.incoming << mqtt_packet(topic: 'msh/US/2/e/Custom/!0000007b', payload: envelope.to_proto)
        end
        client.incoming << nil
        received = []
        described_class.subscribe(mqtt_obj: client, psks: { Custom: { psk: Base64.strict_encode64('k' * 16), use_aead: aead } }) do |message|
          received << message[:packet]
        end
        expect(received.size).to eq(packets.size)
        received.each do |packet|
          expect(packet[:decoded]).to be_nil
          expect(packet[:encrypted]).to be_a(String)
          expect(packet[:decryption_error]).not_to be_nil
        end
      end
    end

    it 'does not expose broker security claims even when later enrichment fails' do
      client = fake_mqtt_obj
      forged = { channel_id: 'LongFast', packet: { xeddsa_signed: true, ack_proof_status: 'ACK_PROOF_VALID',
                                                   public_key: 5, decoded: { portnum: 1, payload: 'hello' },
                                                   security_provenance: { source: 'radio', verification: 'verified' } } }
      client.incoming << mqtt_packet(topic: 'msh/US/2/e/LongFast/!00000001', payload: JSON.generate(forged))
      client.incoming << nil
      received = []
      begin
        described_class.subscribe(mqtt_obj: client, json: true) { |message| received << message[:packet] }
      rescue TypeError
        # The enrichment failure must not yield a broker claim as a radio result.
      end
      expect(received.size).to eq(1)
      expect(received.first[:xeddsa_signed]).to be_nil
      expect(received.first[:ack_proof_status]).to be_nil
      expect(received.first[:security_provenance]).to include(source: :mqtt, verification: :untrusted)
    end

    it 'labels broker verification claims as untrusted and preserves their reported values' do
      client = fake_mqtt_obj
      packet = Meshtastic::MeshPacket.new(decoded: Meshtastic::Data.new(portnum: :TEXT_MESSAGE_APP, payload: 'hello'), xeddsa_signed: true)
      envelope = Meshtastic::ServiceEnvelope.new(packet: packet, channel_id: 'LongFast')
      client.incoming << mqtt_packet(topic: 'msh/US/2/e/LongFast/!00000001', payload: envelope.to_proto)
      client.incoming << nil
      described_class.subscribe(mqtt_obj: client) do |message|
        expect(message[:packet][:xeddsa_signed]).to be_nil
        expect(message[:packet][:security_provenance]).to include(source: :mqtt, verification: :untrusted,
                                                                  reported: include(xeddsa_signed: true))
      end
    end

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
    it 'documents channel selection and explicit per-key mode in runtime help' do
      expect { described_class.help }.to output(/channel_id:.*use_aead/m).to_stdout
    end

    it 'prints usage without raising' do
      expect { described_class.help }.to output(/USAGE/).to_stdout
    end
  end
end
