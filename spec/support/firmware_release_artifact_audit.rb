# frozen_string_literal: true

require 'meshtastic'
require 'digest'
require 'json'

# Opt-in, parser-only audit. No installer, device, subprocess or network calls.
# Extract the named official release members into ARGV[0] before running.
root = ARGV.fetch(0)
firmware = Meshtastic::Admin::Firmware
cases = [
  ['firmware-heltec-ht62-esp32c3-sx1262-2.8.1.8e6a88d.bin', '4bae94b7f5132bff199a8890094a3642c6096bf366dcdf1eb4ba84cdb2b9e290', :bin, nil],
  ['firmware-heltec-ht62-esp32c3-sx1262-2.8.1.8e6a88d.factory.bin', 'da6b9789f869b6b48da7a6532e4b769be4cbb6633a61a9c90eb1d92732784d3c', :bin, 'trailing data'],
  ['firmware-rak4631-2.8.1.8e6a88d.uf2', 'ba35ee9247125dba2551261446b130d861dd00478caaf9ba6377aecbf0b2aa1e', :nrf_uf2, 'outside application flash'],
  ['firmware-rak4631-2.8.1.8e6a88d.hex', '718482dc2a56d8f89b8cf416c775cbb78fb3eee694f6642ab8a6545ba2e8f07b', :hex, nil],
  ['firmware-rak4631-2.8.1.8e6a88d-ota.zip', '2315a758cdfcd635fc5a11341619d67787fddbdf9f0e5778364950c36f4fdeaa', :zip, 'Only application-only legacy Adafruit DFU packages'],
  ['firmware-rak11310-2.8.1.8e6a88d.uf2', '941cc6d0b44ac5498a44c708705a0209509de7183fdc8862fe19a223d9b3d066', :rp_uf2, nil]
]
results = cases.map do |name, digest, kind, expected_error|
  bytes = File.binread(File.join(root, name))
  raise "Release artifact hash mismatch: #{name}" unless Digest::SHA256.hexdigest(bytes) == digest

  error = nil
  begin
    case kind
    when :bin then firmware::SerialBootloader.send(:validate_image, bytes: bytes, chip_id: 5)
    when :nrf_uf2 then firmware::UF2.send(:validate_image, bytes: bytes, family_id: 0xada52840)
    when :rp_uf2 then firmware::UF2.send(:validate_image, bytes: bytes, family_id: 0xe48bff56, flash_size: 2_097_152)
    when :hex then firmware::Hex.validate(bytes: bytes, expected_chip: :nrf52840)
    when :zip then firmware::NordicDFU.send(:package, package_bytes: bytes)
    end
  rescue ArgumentError => e
    error = e.message
  end
  raise "Unexpected parser result for #{name}: #{error || 'accepted'}" unless expected_error ? error&.include?(expected_error) : error.nil?

  { artifact: name, bytes: bytes.bytesize, sha256: digest, parser: error ? :rejected : :accepted, reason: error, hardware: false }
end
puts JSON.pretty_generate(results)
