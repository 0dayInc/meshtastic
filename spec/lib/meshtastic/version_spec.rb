# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::VERSION do
  it 'is defined' do
    expect(Meshtastic::VERSION).not_to be_nil
  end

  it 'is a string' do
    expect(Meshtastic::VERSION).to be_a(String)
  end

  it 'matches the expected pattern' do
    expect(Meshtastic::VERSION).to match(/\d+\.\d+\.\d+/)
  end
end
