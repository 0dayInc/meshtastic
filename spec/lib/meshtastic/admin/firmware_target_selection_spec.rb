# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Meshtastic::Admin::Firmware, 'installer target selection (no hardware)' do
  it 'rejects unimplemented chips before opening a serial programmer' do
    expect(UART).not_to receive(:open)
    %i[esp32c6 rp2350 stm32 nrf52840].each do |chip|
      expect do
        described_class.install(protocol: :esp_rom, chip: chip, bytes: 'image', port: '/dev/ttyACM0', offset: 0x10000, flash_size: 4_194_304)
      end.to raise_error(ArgumentError, /chip must/)
    end
  end

  it 'never guesses a Secure Nordic or unsupported board loader from an artifact' do
    expect(Socket).not_to receive(:tcp)
    expect(UART).not_to receive(:open)
    %i[nordic_secure_dfu rp2350 stm32 mqtt].each do |protocol|
      expect { described_class.install(protocol: protocol, bytes: 'image') }.to raise_error(NotImplementedError)
    end
  end

  it 'does not pretend that full erase is implemented' do
    expect(UART).not_to receive(:open)
    expect(Socket).not_to receive(:tcp)
    %i[esp_rom unified_wifi unified_ble nordic_dfu uf2 swd].each do |protocol|
      expect { described_class.install(protocol: protocol, bytes: 'image', full_erase: true) }.to raise_error(ArgumentError, /[Uu]nsupported|[Uu]nknown/)
    end
  end

  it 'rejects unsupported RP2350 UF2 families before opening a destination' do
    expect(File).not_to receive(:open)
    expect do
      described_class.install(protocol: :uf2, bytes: 'image', family_id: 0xe48bff59, mount: '/selected/volume', board_id: 'RP2350')
    end.to raise_error(ArgumentError, /Unsupported UF2 family/)
  end

  it 'requires the exact supported SWD chip before invoking any programmer' do
    expect(described_class::Hex).not_to receive(:program)
    expect do
      described_class::Hex.validate(bytes: ':00000001FF', expected_chip: :stm32)
    end.to raise_error(ArgumentError, /nrf52840/)
  end
end
