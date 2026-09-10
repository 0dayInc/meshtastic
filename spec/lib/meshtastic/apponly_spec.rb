# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Apponly do
  it 'round-trips a ChannelSet' do
    set = described_class.encode
    expect(described_class.decode(bytes: set.to_proto)).to be_a(Meshtastic::ChannelSet)
  end
end
