# frozen_string_literal: true

require 'spec_helper'

describe Meshtastic::FieldMetadata do
  it 'round trips generated field metadata' do
    message = described_class.new(label: 'Example', admin_only: true)
    expect(described_class.decode(message.to_proto)).to eq(message)
  end

  it 'packages every generated protobuf and its corresponding spec' do
    root = File.expand_path('../../..', __dir__)
    specification = Gem::Specification.load(File.join(root, 'meshtastic.gemspec'))
    Dir.glob('lib/**/*_pb.rb', base: root).each do |path|
      expect(specification.files).to include(path)
      expect(specification.files).to include("spec/#{path.sub(/\.rb\z/, '_spec.rb')}")
    end
  end
end
