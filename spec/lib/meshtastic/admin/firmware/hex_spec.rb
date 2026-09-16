# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'rbconfig'
require 'open3'
require 'meshtastic/admin/firmware/hex' if File.file?(File.expand_path('../../../../../lib/meshtastic/admin/firmware/hex.rb', __dir__))

describe 'Meshtastic::Admin::Firmware::Hex' do
  def record(type, address = 0, data = [])
    bytes = [data.length, address >> 8, address & 255, type] + data
    ":#{(bytes + [(-bytes.sum) & 255]).pack('C*').unpack1('H*').upcase}\n"
  end

  def backend
    Meshtastic::Admin::Firmware.const_get(:Hex)
  end

  let(:image) { record(0, 0, [1, 2, 3, 4]) + record(1) }

  it 'runs a real fake executable with guarded write, verify and reset commands' do
    Dir.mktmpdir('hex test ;[]$') do |dir|
      executable = File.join(dir, 'fake openocd')
      log = File.join(dir, 'argv.json')
      File.write(executable, <<~RUBY)
        #!#{RbConfig.ruby}
        require 'json'
        File.write(#{log.inspect}, JSON.generate(ARGV))
        script = ARGV.last
        puts script[/MESHTASTIC_HEX_OK_[a-f0-9]+/]
      RUBY
      File.chmod(0o700, executable)
      config = File.join(dir, 'trusted.cfg')
      File.write(config, '# trusted test configuration')
      firmware = File.join(dir, 'input ;[$].hex')
      File.binwrite(firmware, image)
      result = backend.install(protocol: :swd, firmware: firmware, expected_chip: :nrf52840,
                               expected_target: 'nrf52.cpu', openocd: executable,
                               interface_config: config, target_config: config)
      expect(result).to include(status: :verified, flash_verified: true, reboot_verified: false)
      args = JSON.parse(File.read(log))
      expect(args).to include(config, 'transport select swd')
      script = args.last
      expect(script).to include('0x10000100', '0x52840', 'flash write_image erase', 'verify_image', 'reset run', 'shutdown error')
      expect(script.index('0x10000100')).to be < script.index('flash write_image erase')
      expect(script.index('verify_image')).to be < script.index('reset run')
      expect(script).not_to include('mass_erase')
    end
  end

  it 'quotes braces and substitution characters even inside a braced Tcl catch' do
    value = '/tmp/a}b{c\\d"e[$x];file.hex'
    word = backend.send(:tcl_word, value: value)
    output, error, status = Open3.capture3('tclsh', stdin_data: "if {[catch {set path #{word}; puts $path} failure]} {puts stderr $failure; exit 1}\n")
    expect(status.success?).to be(true), error
    expect(output.chomp).to eq(value)
  end

  it 'rejects malformed records, unknown types, missing EOF and overlaps' do
    invalid = [image.sub('01020304', '01020305'), image.sub(':04', ':05'), image + record(1),
               record(0, 0, [1]), record(1), "\n#{image}", "#{image}\n", ':zz',
               record(6) + image, record(1, 1), record(1, 0, [1]),
               record(2, 1, [0, 0]) + image, record(4, 0, [0]) + image,
               record(0, 0, []) + record(1), record(0, 65_535, [1, 2]) + record(1),
               record(0, 0, [1, 2]) + record(0, 1, [2]) + record(1),
               record(4, 0, [255, 255]) + record(0, 65_535, [1]) + record(1),
               (record(5, 0, [0, 0, 0, 1]) * 2) + image,
               record(5, 0, [0, 16, 0, 0]) + image]
    invalid.each do |bytes|
      expect { backend.validate(bytes: bytes, expected_chip: :nrf52840) }.to raise_error(ArgumentError)
    end
    expect { backend.validate(bytes: image, expected_chip: :nrf52832) }.to raise_error(ArgumentError)
  end

  it 'handles segment and linear bases, UICR, CRLF and start records' do
    bytes = record(2, 0, [0x10, 0]) + record(0, 0, [1]) + record(4, 0, [0x10, 0]) +
            record(0, 0x1000, [2]) + record(5, 0, [0, 1, 0, 1]) + record(1)
    expect(backend.validate(bytes: bytes.gsub("\n", "\r\n"), expected_chip: :nrf52840)).to include(ranges: [[0x10000, 0x10001], [0x10001000, 0x10001001]], start_address: 0x10001)
    bytes = record(3, 0, [0x10, 0, 0, 1]) + image
    expect(backend.validate(bytes: bytes, expected_chip: :nrf52840)[:start_address]).to eq(0x10001)
  end

  it 'requires actual subprocess success and a completion marker and bounds runtime' do
    Dir.mktmpdir do |dir|
      executable = File.join(dir, 'openocd')
      config = File.join(dir, 'config')
      File.write(config, '# test')
      options = { protocol: :swd, bytes: image, expected_chip: :nrf52840, expected_target: 'nrf52.cpu',
                  openocd: executable, interface_config: config, target_config: config }
      ['exit 0', 'puts ARGV.last[/MESHTASTIC_HEX_OK_[a-f0-9]+/]; exit 1', 'sleep 10'].each do |body|
        File.write(executable, "#!#{RbConfig.ruby}\n#{body}\n")
        File.chmod(0o700, executable)
        expect { backend.install(options.merge(timeout: 0.2)) }.to raise_error(IOError)
      end
      File.write(executable, "#!#{RbConfig.ruby}\nabort 'must not run'\n")
      [{ bytes: image.sub('01020304', '01020305') }, { expected_target: 'x;exit' },
       { expected_chip: :esp32 }, { protocol: :serial }, { firmware: '/tmp/also.hex' },
       { timeout: 0 }, { target_config: nil }, { openocd: 'openocd' }, { surprise: true }].each do |change|
        expect { backend.install(options.merge(change)) }.to raise_error(ArgumentError)
      end
    end
  end

  it 'executes Tcl guards before erase and refuses failed verification or reset' do
    Dir.mktmpdir do |dir|
      executable = File.join(dir, 'openocd')
      config = File.join(dir, 'config')
      trace = File.join(dir, 'trace')
      File.write(config, '# test')
      options = { protocol: :swd, bytes: image, expected_chip: :nrf52840, expected_target: 'nrf52.cpu',
                  openocd: executable, interface_config: config, target_config: config }
      %w[success chip verify reset].each do |mode|
        simulator = <<~TCL
          set trace [open #{backend.send(:tcl_word, value: trace)} w]
          proc init {} {}
          proc targets {name} {if {$name ne "nrf52.cpu"} {error "wrong target"}}
          proc reset {mode} {
            if {$mode eq "run" && "#{mode}" eq "reset"} {error "reset failed"}
            puts $::trace "reset $mode"
          }
          proc halt {} {}
          proc read_memory {address width count} {
            if {$address == 0x10000100} {return #{mode == 'chip' ? '0x52832' : '0x52840'}}
            if {$address == 0x10000010} {return 4096}
            return 256
          }
          proc flash {args} {puts $::trace flash}
          proc verify_image {args} {
            puts $::trace verify
            if {"#{mode}" eq "verify"} {error "verification failed"}
          }
          proc echo {text} {puts $text}
          proc shutdown {args} {close $::trace; if {[llength $args]} {exit 1}; exit 0}
        TCL
        File.write(executable, <<~RUBY)
          #!#{RbConfig.ruby}
          require 'open3'
          output, error, status = Open3.capture3('tclsh', stdin_data: #{simulator.inspect} + ARGV.last)
          print output
          warn error unless error.empty?
          exit status.exitstatus
        RUBY
        File.chmod(0o700, executable)
        if mode == 'success'
          expect(backend.install(options)[:flash_verified]).to be(true)
          expect(File.read(trace)).to eq("reset init\nflash\nverify\nreset run\n")
        else
          expect { backend.install(options) }.to raise_error(IOError)
          expect(File.read(trace)).not_to include('reset run')
          expect(File.read(trace)).not_to include('flash') if mode == 'chip'
        end
      end
    end
  end

  it 'validates Intel HEX bytes without a programmer or hardware' do
    expect(backend.validate(bytes: image, expected_chip: :nrf52840)).to include(data_bytes: 4, ranges: [[0, 4]])
  end
end
