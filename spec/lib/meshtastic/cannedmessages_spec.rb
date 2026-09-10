# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Cannedmessages do
  it 'encodes canned message lines' do
    expect(described_class.encode(messages: "Yes\nNo").messages).to eq("Yes\nNo")
  end
end
