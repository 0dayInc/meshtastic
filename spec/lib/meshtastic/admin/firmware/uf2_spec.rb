# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'meshtastic/admin/firmware/uf2' if File.exist?(File.expand_path('../../../../../lib/meshtastic/admin/firmware/uf2.rb', __dir__))

shared_context 'UF2 bootloader files' do
  def block(opts = {})
    defaults = { number: 0, count: 1, address: 0x27000, family: 0xada52840, flags: 0x2000, size: 256 }.merge(opts)
    [0x0a324655, 0x9e5d5157, defaults[:flags], defaults[:address], defaults[:size], defaults[:number], defaults[:count], defaults[:family]].pack('V8') + ('x' * 256).ljust(476, "\0") + [0x0ab16f30].pack('V')
  end

  around do |example|
    Dir.mktmpdir('meshtastic-uf2-') do |dir|
      @mount = File.join(dir, 'boot')
      Dir.mkdir(@mount)
      File.write(File.join(@mount, 'INFO_UF2.TXT'), "UF2 Bootloader 0.9.2\nModel: Test board\nBoard-ID: nRF52840-Test-v1\n")
      @options = { protocol: :uf2, bytes: block, mount: @mount, board_id: 'nRF52840-Test-v1', family_id: 0xada52840 }
      example.run
    end
  end
end

describe 'Meshtastic::Admin::Firmware::UF2 image validation' do
  include_context 'UF2 bootloader files'

  {
    empty: -> { ''.b },
    truncated: -> { block.byteslice(0, 511) },
    trailing: -> { "#{block}x" },
    mixed_families: -> { block(count: 2) + block(number: 1, count: 2, address: 0x27100, family: 0xe48bff56) },
    duplicate_blocks: -> { block(count: 2) * 2 },
    missing_block: -> { block(count: 2) },
    inconsistent_count: -> { block(count: 2) + block(number: 1, address: 0x27100) },
    out_of_range_number: -> { block(number: 1) },
    no_family: -> { block(flags: 0) },
    not_main_flash: -> { block(flags: 0x2001) },
    file_container: -> { block(flags: 0x3000) },
    md5_extension: -> { block(flags: 0x6000) },
    extension_tags: -> { block(flags: 0xa000) },
    unknown_flags: -> { block(flags: 0x12000) },
    zero_payload: -> { block(size: 0) },
    unsupported_page_size: -> { block(size: 128) },
    unsupported_page_alignment: -> { block(address: 0x27004) },
    oversized_payload: -> { block(size: 480) },
    unaligned_payload: -> { block(size: 255) },
    unaligned_address: -> { block(address: 0x27001) },
    bootloader_address: -> { block(address: 0xf4000) },
    softdevice_address: -> { block(address: 0) },
    crossing_boundary: -> { block(address: 0xf3ffc) },
    overflow_address: -> { block(address: 0xfffffffc) },
    overlap: -> { block(count: 2) + block(number: 1, count: 2, address: 0x27000) }
  }.each do |name, image|
    it "rejects #{name} before creating the destination" do
      expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(bytes: instance_exec(&image))) }.to raise_error(ArgumentError)
      expect(Dir.children(@mount)).to eq(['INFO_UF2.TXT'])
    end
  end

  it 'rejects numeric lookalikes for family identifiers' do
    expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(family_id: 0xada52840.to_f)) }.to raise_error(ArgumentError)
    expect(Dir.children(@mount)).to eq(['INFO_UF2.TXT'])
  end

  it 'checks every magic word in every block' do
    [0, 4, 508].each do |offset|
      bytes = block(count: 2) + block(number: 1, count: 2, address: 0x27100)
      bytes.setbyte(512 + offset, 0)
      expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(bytes: bytes)) }.to raise_error(ArgumentError, /magic/)
    end
  end

  it 'requires explicit :uf2 protocol and rejects unknown options' do
    [@options.except(:protocol), @options.merge(protocol: :esp_rom), @options.merge(offset: 0)].each do |options|
      expect { Meshtastic::Admin::Firmware::UF2.install(options) }.to raise_error(ArgumentError)
    end
    expect(Dir.children(@mount)).to eq(['INFO_UF2.TXT'])
  end

  it 'validates the source file and accepts exactly one immutable snapshot' do
    source = File.join(File.dirname(@mount), 'input.uf2')
    File.binwrite(source, block)
    expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(firmware: source)) }.to raise_error(ArgumentError)
    result = Meshtastic::Admin::Firmware::UF2.install(@options.except(:bytes).merge(firmware: source))
    expect(result[:sha256]).to eq(Digest::SHA256.hexdigest(File.binread(source)))
    expect(File.binread(File.join(@mount, 'FIRMWARE.UF2'))).to eq(File.binread(source))
  end

  it 'rejects missing or non-string bytes and unknown families before writing' do
    [@options.except(:bytes), @options.merge(bytes: nil), @options.merge(bytes: 42), @options.merge(family_id: 123)].each do |options|
      expect { Meshtastic::Admin::Firmware::UF2.install(options) }.to raise_error(ArgumentError)
    end
  end

  it 'submits an RP2040 flash image only inside the explicitly supplied flash capacity' do
    File.write(File.join(@mount, 'INFO_UF2.TXT'), "UF2 Bootloader v3.0\nModel: Raspberry Pi RP2\nBoard-ID: RPI-RP2\n")
    options = @options.merge(bytes: block(address: 0x10000000, family: 0xe48bff56), board_id: 'RPI-RP2', family_id: 0xe48bff56)
    expect { Meshtastic::Admin::Firmware::UF2.install(options) }.to raise_error(ArgumentError, /flash_size/)
    result = Meshtastic::Admin::Firmware::UF2.install(options.merge(flash_size: 2 * 1024 * 1024))
    expect(result[:status]).to eq(:copied)
    expect(File.binread(result[:destination])).to eq(options[:bytes])
  end

  it 'rejects RP2040 RAM, flash overflow and invalid capacities' do
    File.write(File.join(@mount, 'INFO_UF2.TXT'), "UF2 Bootloader v3.0\nBoard-ID: RPI-RP2\n")
    options = @options.merge(board_id: 'RPI-RP2', family_id: 0xe48bff56, flash_size: 2 * 1024 * 1024)
    [0x20000000, 0x10200000, 0x101ffffc].each do |address|
      expect { Meshtastic::Admin::Firmware::UF2.install(options.merge(bytes: block(address: address, family: 0xe48bff56))) }.to raise_error(ArgumentError)
    end
    [0, -1, '2097152', 32 * 1024 * 1024].each do |size|
      expect { Meshtastic::Admin::Firmware::UF2.install(options.merge(flash_size: size)) }.to raise_error(ArgumentError)
    end
  end
end

describe 'Meshtastic::Admin::Firmware::UF2 mount safety' do
  include_context 'UF2 bootloader files'

  it 'refuses a directory without INFO_UF2.TXT' do
    File.unlink(File.join(@mount, 'INFO_UF2.TXT'))
    expect { Meshtastic::Admin::Firmware::UF2.install(@options) }.to raise_error(ArgumentError, /INFO_UF2/)
    expect(Dir.children(@mount)).to be_empty
  end

  it 'requires a canonical absolute directory selected by the caller' do
    [nil, '', '.', '/', File.join(@mount, '..', 'boot')].each do |mount|
      expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(mount: mount)) }.to raise_error(ArgumentError)
    end
    expect(Dir.children(@mount)).to eq(['INFO_UF2.TXT'])
  end

  it 'refuses a symlinked directory or parent directory' do
    link = File.join(File.dirname(@mount), 'link')
    File.symlink(@mount, link)
    expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(mount: link)) }.to raise_error(ArgumentError)
    File.unlink(link)
    File.symlink(File.dirname(@mount), link)
    expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(mount: File.join(link, 'boot'))) }.to raise_error(ArgumentError)
    expect(Dir.children(@mount)).to eq(['INFO_UF2.TXT'])
  end

  it 'refuses a symlinked or nonregular marker' do
    marker = File.join(@mount, 'INFO_UF2.TXT')
    saved = File.join(File.dirname(@mount), 'saved')
    File.rename(marker, saved)
    File.symlink(saved, marker)
    expect { Meshtastic::Admin::Firmware::UF2.install(@options) }.to raise_error(ArgumentError)
    File.unlink(marker)
    File.mkfifo(marker)
    expect { Meshtastic::Admin::Firmware::UF2.install(@options) }.to raise_error(ArgumentError)
    expect(Dir.children(@mount)).to eq(['INFO_UF2.TXT'])
  end

  it 'checks the exact expected Board-ID and its MCU family' do
    expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(board_id: 'nRF52840-Other-v1')) }.to raise_error(ArgumentError)
    File.write(File.join(@mount, 'INFO_UF2.TXT'), "UF2 Bootloader v3.0\nBoard-ID: RPI-RP2\n")
    expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(board_id: 'RPI-RP2')) }.to raise_error(ArgumentError)
    expect(Dir.children(@mount)).to eq(['INFO_UF2.TXT'])
  end

  it 'rejects malformed, oversized, missing and duplicate board metadata' do
    ["Board-ID: nRF52840-Test-v1\n", "UF2 Bootloader\n", "UF2 Bootloader\nBoard-ID: nRF52840-Test-v1\nBoard-ID: nRF52840-Test-v1\n", 'x' * 4097].each do |text|
      File.write(File.join(@mount, 'INFO_UF2.TXT'), text)
      expect { Meshtastic::Admin::Firmware::UF2.install(@options) }.to raise_error(ArgumentError)
      expect(Dir.children(@mount)).to eq(['INFO_UF2.TXT'])
    end
  end

  it 'recognizes the lowercase standard marker filename' do
    File.rename(File.join(@mount, 'INFO_UF2.TXT'), File.join(@mount, 'info_uf2.txt'))
    expect(Meshtastic::Admin::Firmware::UF2.install(@options)[:status]).to eq(:copied)
  end

  it 'never overwrites existing destinations or follows destination symlinks' do
    destination = File.join(@mount, 'FIRMWARE.UF2')
    File.write(destination, 'existing')
    expect { Meshtastic::Admin::Firmware::UF2.install(@options) }.to raise_error(Errno::EEXIST)
    expect(File.read(destination)).to eq('existing')
    File.unlink(destination)
    outside = File.join(File.dirname(@mount), 'outside')
    File.write(outside, 'untouched')
    File.symlink(outside, destination)
    expect { Meshtastic::Admin::Firmware::UF2.install(@options) }.to raise_error(Errno::EEXIST)
    expect(File.read(outside)).to eq('untouched')
  end

  it 'does not redirect writes when the chosen mount is replaced during validation' do
    original_mount = "#{@mount}-old"
    allow(File).to receive(:stat).and_call_original
    allow(File).to receive(:stat).with(@mount).and_wrap_original do |method, path|
      File.rename(@mount, original_mount)
      Dir.mkdir(@mount)
      method.call(path)
    end
    expect { Meshtastic::Admin::Firmware::UF2.install(@options) }.to raise_error(IOError, /mount changed/)
    expect(Dir.children(@mount)).to be_empty
    expect(Dir.children(original_mount)).to eq(['INFO_UF2.TXT'])
  end

  it 'propagates disconnect or fsync failure without claiming success or retrying' do
    attempts = 0
    allow(File).to receive(:open).and_wrap_original do |method, path, *args, &callback|
      if path.end_with?('/FIRMWARE.UF2')
        attempts += 1
        method.call(path, *args) do |file|
          allow(file).to receive(:fsync).and_raise(Errno::ENODEV)
          callback.call(file)
        end
      else
        method.call(path, *args, &callback)
      end
    end
    expect { Meshtastic::Admin::Firmware::UF2.install(@options) }.to raise_error(Errno::ENODEV)
    expect(attempts).to eq(1)
  end

  it 'allows shuffled blocks and holes without reinterpreting addresses or reordering bytes' do
    bytes = block(number: 1, count: 2, address: 0x28000) + block(count: 2)
    Meshtastic::Admin::Firmware::UF2.install(@options.merge(bytes: bytes))
    expect(File.binread(File.join(@mount, 'FIRMWARE.UF2'))).to eq(bytes)
  end

  it 'rejects a raw binary image without writing anything' do
    expect { Meshtastic::Admin::Firmware::UF2.install(@options.merge(bytes: 'x' * 512)) }.to raise_error(ArgumentError, /magic/)
    expect(Dir.children(@mount)).to eq(['INFO_UF2.TXT'])
  end

  it 'copies intact UF2 bytes to an explicitly selected bootloader without claiming flash verification' do
    expect(Meshtastic::Admin::Firmware.const_defined?(:UF2)).to be true
    result = Meshtastic::Admin::Firmware::UF2.install(@options)
    expect(File.binread(File.join(@mount, 'FIRMWARE.UF2'))).to eq(block)
    expect(result).to include(status: :copied, protocol: :uf2, bytes: 512, family_id: 0xada52840, board_id: 'nRF52840-Test-v1', flash_verified: false, reboot_verified: false)
  end
end
