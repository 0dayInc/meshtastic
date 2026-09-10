# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic do
  it 'requires a transport for deliver_data' do
    expect { described_class.deliver_data(data: Meshtastic::Data.new) }.to raise_error(ArgumentError, /serial_obj/)
  end
end
