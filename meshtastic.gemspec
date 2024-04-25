# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'meshtastic/version'

Gem::Specification.new do |spec|
  ruby_version = ">= #{File.read('.ruby-version').split('-').last.chomp}".freeze
  # spec.required_ruby_version = ruby_version
  spec.required_ruby_version = '>= 3.3.0'
  spec.name = 'meshtastic'
  spec.version = Meshtastic::VERSION
  spec.authors = ['0day Inc.']
  spec.email = ['request.pentest@0dayinc.com']
  spec.summary = 'Automated Security Testing for CI/CD Pipelines & Beyond'
  spec.description = 'https://github.com/0dayinc/meshtastic/README.md'
  spec.homepage = 'https://github.com/0dayinc/meshtastic'
  spec.license = 'MIT'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = `git ls-files -z`.split("\x00")
  spec.executables = spec.files.grep(%r{^bin/}) do |f|
    File.basename(f)
  end

  spec_tests = spec.files.grep(%r{^spec/})
  meshtastic_modules = spec.files.grep(%r{^lib/})

  missing_rspec = false
  meshtastic_modules.each do |mod_path|
    spec_dirname_for_mod = "spec/#{File.dirname(mod_path)}"
    spec_test_for_mod = "#{File.basename(mod_path).split('.').first}_spec.rb"
    spec_path_for_mod = "#{spec_dirname_for_mod}/#{spec_test_for_mod}"
    next unless spec_tests.grep(/#{spec_path_for_mod}/).empty?

    missing_rspec = true
    error_msg = "ERROR: No RSpec: #{spec_path_for_mod} for Meshtastic Module: #{mod_path}"
    # Display error message in red (octal encoded ansi sequence)
    puts "\001\e[1m\002\001\e[31m\002#{error_msg}\001\e[0m\002"
  end

  raise if missing_rspec

  spec.require_paths = ['lib']

  dev_dependency_arr = %i[
    bundler
    rake
    rdoc
    rspec
  ]

  File.readlines('./Gemfile').each do |line|
    columns = line.chomp.split
    next unless columns.first == 'gem'

    gem_name = columns[1].delete("'").delete(',')
    gem_version = columns.last.delete("'")

    if dev_dependency_arr.include?(gem_name.to_sym)
      spec.add_development_dependency(
        gem_name,
        gem_version
      )
    else
      spec.add_runtime_dependency(
        gem_name,
        gem_version
      )
    end
  end
end
