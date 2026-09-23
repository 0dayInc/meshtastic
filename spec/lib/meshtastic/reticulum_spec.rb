# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Meshtastic::Reticulum' do
  let(:fixtures) { JSON.parse(File.read(File.expand_path('../../support/reticulum_fixtures.json', __dir__))) }
  let(:chunks) { fixtures.fetch('chunks_hex').map { |hex| [hex].pack('H*') } }

  it 'loads the tunnel codec from the gem entrypoint' do
    expect(Meshtastic.const_defined?(:Reticulum)).to be(true)
  end

  it 'packages the upstream JSON fixture even without a Git file listing' do
    root = File.expand_path('../../..', __dir__)
    context = Object.new
    allow(context).to receive(:`).with('git ls-files -z').and_return('')
    path = File.join(root, 'meshtastic.gemspec')
    specification = context.instance_eval(File.read(path), path)
    expect(specification.files).to include('spec/support/reticulum_fixtures.json')
  end

  it 'recognizes upstream REQ control without feeding its bytes to an RNS decoder' do
    require 'meshtastic/reticulum'
    raw = [fixtures.fetch('request_hex')].pack('H*')
    expect(Meshtastic::Reticulum.decode_packet(payload: raw)).to include(
      format: :reticulum_request, message_index: 255, position: 2, index: 2, raw: raw, complete: false
    )
  end

  it 'rejects malformed frames and bounds every wire input before copying' do
    require 'meshtastic/reticulum'
    [nil, 12, '', "\x01", "\x01\x00x", "\x01\xff", 'REQ', "REQ\x01", "REQ\x01\x00", "REQ\x01\x01x", "\x01\xff#{'x' * 201}"].each do |raw|
      expect { Meshtastic::Reticulum.decode_packet(payload: raw) }.to raise_error(ArgumentError)
    end
  end

  it 'retains an opaque complete single fragment and handles signed byte extremes' do
    require 'meshtastic/reticulum'
    raw = [fixtures.fetch('single_hex')].pack('H*')
    expect(Meshtastic::Reticulum.decode_packet(payload: raw)).to include(complete: true, count: 1, message_index: 0, raw: raw)
    expect(Meshtastic::Reticulum.decode_packet(payload: "\xff\x80x".b)).to include(position: -128, count: 128)
    expect(Meshtastic::Reticulum.decode_packet(payload: "\x00\x7fx".b)).to include(position: 127, count: nil)
  end

  it 'reassembles a complete explicitly grouped upstream message final-first without inner decoding' do
    require 'meshtastic/reticulum'
    result = Meshtastic::Reticulum.decode_chunks(chunks: chunks.reverse)
    expect(result).to include(format: :reticulum_packet, complete: true, message_index: 255,
                              count: 3, body: [fixtures.fetch('payload_hex')].pack('H*'), raw_chunks: chunks)
    expect(result[:fragments].map { |frame| frame[:position] }).to eq([1, 2, -3])
  end

  it 'rejects incomplete, duplicate, conflicting, mixed-index and control-containing groups' do
    require 'meshtastic/reticulum'
    cases = [nil, [], chunks * 43, chunks.first(2), [chunks.last], chunks + [chunks.first],
             [chunks.first, "\xff\x01different".b, chunks.last],
             [chunks.first, "\xff\xfex".b, chunks.last],
             [chunks.first, "\x00\x02x".b, chunks.last],
             [chunks.first, "\xff\x04x".b, chunks.last],
             ["REQ\xff\x02".b]]
    cases.each do |group|
      expect { Meshtastic::Reticulum.decode_chunks(chunks: group) }.to raise_error(ArgumentError)
    end
  end

  it 'bounds aggregate output and rejects invalid caller limits' do
    require 'meshtastic/reticulum'
    [0, -1, 565, '564', 1.5].each do |limit|
      expect { Meshtastic::Reticulum.decode_chunks(chunks: chunks, max_bytes: limit) }.to raise_error(ArgumentError)
    end
    expect { Meshtastic::Reticulum.decode_chunks(chunks: chunks, max_bytes: 563) }.to raise_error(ArgumentError, /limit/)
    big = ["\x01\x01#{'x' * 200}", "\x01\x02#{'x' * 200}", "\x01\xfd#{'x' * 165}"]
    expect { Meshtastic::Reticulum.decode_chunks(chunks: big) }.to raise_error(ArgumentError, /limit/)
  end

  it 'exposes usable runtime help and attribution' do
    require 'meshtastic/reticulum'
    expect { Meshtastic::Reticulum.help }.to output(/decode_packet.*payload:.*decode_chunks.*chunks:.*max_bytes:.*authors/m).to_stdout
    expect(Meshtastic::Reticulum.authors).to include('landandair')
  end

  it 'decodes the two byte unsigned/signed upstream header and retains original bytes' do
    require 'meshtastic/reticulum'
    result = Meshtastic::Reticulum.decode_packet(payload: chunks.last)
    expect(result).to include(format: :reticulum_fragment, message_index: 255, position: -3,
                              index: 3, count: 3, final: true, complete: false,
                              raw: chunks.last, body: chunks.last.byteslice(2..))
    expect(result[:raw].encoding).to eq(Encoding::BINARY)
  end
end
