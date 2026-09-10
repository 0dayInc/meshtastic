# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Clientonly do
  it 'encodes a DeviceProfile' do
    profile = described_class.encode(long_name: 'Node', short_name: 'N1')
    expect(profile.long_name).to eq('Node')
    expect(profile.short_name).to eq('N1')
  end
end
