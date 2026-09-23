# frozen_string_literal: true

require 'spec_helper'
require 'meshtastic/forwarder_pb'

RSpec.describe Meshtastic::ForwarderProtobuf::CotEvent do
  it 'loads the complete pinned upstream descriptor graph' do
    expect(described_class.decode("\x0a\x04test".b).uid).to eq('test')
    expect(described_class.descriptor.lookup('detail').subtype.count).to eq(22)
  end
end
