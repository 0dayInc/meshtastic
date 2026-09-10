# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Portnums do
  it 'resolves names and numbers' do
    expect(described_class.lookup(:TEXT_MESSAGE_APP)).to eq(1)
    expect(described_class.lookup(1)).to eq(:TEXT_MESSAGE_APP)
  end
end
