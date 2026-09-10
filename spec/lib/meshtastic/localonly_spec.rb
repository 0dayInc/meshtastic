# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Localonly do
  it 'decodes an empty LocalConfig' do
    expect(described_class.decode_config(Meshtastic::LocalConfig.new.to_proto)).to be_a(Meshtastic::LocalConfig)
  end
end
