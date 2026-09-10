# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::ConnectionStatus do
  it 'decodes DeviceConnectionStatus bytes' do
    expect(described_class.decode(bytes: Meshtastic::DeviceConnectionStatus.new.to_proto)).to be_a(Meshtastic::DeviceConnectionStatus)
  end
end
