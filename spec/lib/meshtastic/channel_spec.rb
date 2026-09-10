# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Channel do
  it 'is the generated Channel protobuf' do
    expect(described_class.new).to be_a(Google::Protobuf::MessageExts)
  end
end
