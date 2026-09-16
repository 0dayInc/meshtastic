# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::ModuleConfig do
  %i[serial_obj bluetooth_obj tcp_obj mqtt_obj transport_obj].each do |key|
    it "translates #{key} to the Admin connection option without mutating options" do
      connection = { marker: Object.new }
      options = { key => connection, to: '!aabbccdd' }.freeze
      expect(Meshtastic::Admin).to receive(:send).with({ transport_obj: connection, to: '!aabbccdd', get_module_config_request: :MQTT_CONFIG }).and_return(:submitted)
      expect(described_class.get(options)).to eq(:submitted)
    end

    it "translates #{key} for setters" do
      connection = { marker: Object.new }
      value = Meshtastic::ModuleConfig.new
      expect(Meshtastic::Admin).to receive(:send).with({ transport_obj: connection, module_config: value, set_module_config: value }).and_return(:submitted)
      expect(described_class.set({ key => connection, module_config: value }.freeze)).to eq(:submitted)
    end
  end

  %i[get set].each do |operation|
    %i[transport_obj serial_obj bluetooth_obj tcp_obj mqtt_obj].combination(2) do |first, second|
      it "rejects ambiguous #{first}/#{second} connections for #{operation}" do
        connection = fake_serial_obj
        expect(Meshtastic::Admin).not_to receive(:send)
        expect { described_class.public_send(operation, { first => connection, second => connection, module_config: Meshtastic::ModuleConfig.new }) }
          .to raise_error(ArgumentError, /connection|transport/i)
        expect(connection[:written]).to be_empty
      end
    end
  end

  it 'documents the canonical connection option in help' do
    expect { described_class.help }.to output(/transport_obj: connection/).to_stdout
  end

  %i[serial_obj transport_obj].each do |key|
    %i[get set].each do |operation|
      it "encodes a real Admin packet for #{operation} with #{key}" do
        connection = fake_serial_obj
        options = { key => connection, module_config: Meshtastic::ModuleConfig.new }
        options[:bluetooth_obj] = nil
        described_class.public_send(operation, options.freeze)
        frame = connection[:written]
        packet = Meshtastic::ToRadio.decode(frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))).packet
        admin = Meshtastic::AdminMessage.decode(packet.decoded.payload)
        expect(admin.payload_variant).to eq(operation == :get ? :get_module_config_request : :set_module_config)
      end
    end
  end

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

  it 'requests MQTT module config via Admin' do
    serial_obj = fake_serial_obj
    described_class.get(serial_obj: serial_obj, module_config_type: :MQTT_CONFIG)
    frame = serial_obj[:written]
    packet = Meshtastic::ToRadio.decode(frame.byteslice(4, (frame.getbyte(2) << 8) + frame.getbyte(3))).packet
    admin = Meshtastic::AdminMessage.decode(packet.decoded.payload)
    expect(admin.get_module_config_request).to eq(:MQTT_CONFIG)
  end
end
