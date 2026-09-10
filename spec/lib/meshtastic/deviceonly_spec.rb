# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Deviceonly do
  it 'decodes an empty DeviceState' do
    expect(described_class.decode_state(Meshtastic::DeviceState.new.to_proto)).to be_a(Meshtastic::DeviceState)
  end
end
