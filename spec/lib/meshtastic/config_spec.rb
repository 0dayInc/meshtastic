# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Config do
  it 'is the generated Config protobuf' do
    expect(described_class.new).to be_a(Google::Protobuf::MessageExts)
  end
end
