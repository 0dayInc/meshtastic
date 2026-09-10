# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::Xmodem do
  it 'encodes an XModem SOH packet' do
    packet = described_class.encode(control: :SOH, seq: 1, buffer: 'A')
    expect(packet.control).to eq(:SOH)
    expect(packet.seq).to eq(1)
  end
end
