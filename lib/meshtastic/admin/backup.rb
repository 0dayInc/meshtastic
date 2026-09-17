# frozen_string_literal: true

require 'json'
require 'base64'
require 'uri'
require 'stringio'
require 'meshtastic/clientonly_pb'
require 'meshtastic/admin/channel'
require 'meshtastic/admin'

module Meshtastic
  module Admin
    # Host-side snapshots, not firmware filesystem backup commands.
    module Backup
      FORMAT = 'meshtastic-admin-backup'
      WARNING = 'Contains secrets returned by firmware. Firmware may redact secrets; absent/default values are not proof of completeness. Owner identity and hardware metadata are excluded. ACKs do not prove persistence.'
      CONFIG_TYPES = %i[DEVICE_CONFIG POSITION_CONFIG POWER_CONFIG NETWORK_CONFIG DISPLAY_CONFIG LORA_CONFIG BLUETOOTH_CONFIG SECURITY_CONFIG].freeze
      MODULE_TYPES = %i[MQTT_CONFIG SERIAL_CONFIG EXTNOTIF_CONFIG STOREFORWARD_CONFIG RANGETEST_CONFIG TELEMETRY_CONFIG CANNEDMSG_CONFIG AUDIO_CONFIG REMOTEHARDWARE_CONFIG NEIGHBORINFO_CONFIG AMBIENTLIGHTING_CONFIG DETECTIONSENSOR_CONFIG PAXCOUNTER_CONFIG STATUSMESSAGE_CONFIG TRAFFICMANAGEMENT_CONFIG TAK_CONFIG MESHBEACON_CONFIG].freeze
      OWNER_FIELDS = %w[long_name short_name is_licensed].freeze

      # JSON 2.x otherwise silently keeps the last duplicate key.
      class StrictObject < Hash
        def []=(key, value)
          raise ArgumentError, 'duplicate JSON key' if key?(key)

          super
        end
      end
      private_constant :StrictObject

      public_class_method def self.export(opts = {})
        validate_options(options: opts, operation: :export)
        connection = connection_options(opts)
        return export_profile(opts.merge(connection: connection)) if opts.fetch(:format, :json) == :device_profile

        records = []
        selection(opts).each do |section, slot|
          value = Admin.request(connection.merge(read_command(section: section, slot: slot)))[:value]
          value = Meshtastic::User.new(long_name: value.long_name, short_name: value.short_name, is_licensed: value.is_licensed) if section == 'owner'
          json = JSON.parse(value.class.encode_json(value, emit_defaults: true, preserve_proto_fieldnames: true))
          json.select! { |key, _| OWNER_FIELDS.include?(key) } if section == 'owner'
          records << { 'section' => section, 'slot' => slot, 'value' => json }
        end
        document = { 'format' => FORMAT, 'version' => 1, 'warning' => WARNING, 'records' => records }
        validate_document(document: document)
        if opts[:path]
          File.open(opts[:path], File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
            file.chmod(0o600)
            file.write(JSON.pretty_generate(document))
            file.flush
            file.fsync
          end
        end
        { status: :exported, count: records.length, backup: document, warnings: [WARNING] }
      end

      private_class_method def self.export_profile(opts = {})
        selected = selection(opts)
        raise ArgumentError, 'DeviceProfile cannot represent UI configuration' if opts.fetch(:include_ui, false)

        indexes = opts.fetch(:channel_indexes, (0..7).to_a)
        raise ArgumentError, 'DeviceProfile channels must be an ordered contiguous prefix starting at zero' unless indexes == (0...indexes.length).to_a
        raise ArgumentError, 'DeviceProfile selection is empty' if selected.empty? && !opts.key?(:fixed_position)

        profile = Meshtastic::DeviceProfile.new
        profile.fixed_position = profile_position(value: opts[:fixed_position]) if opts.key?(:fixed_position)
        channels = []
        selected.each do |section, slot|
          value = Admin.request(opts[:connection].merge(read_command(section: section, slot: slot)))[:value]
          case section
          when 'owner'
            OWNER_FIELDS.each { |name| profile[name] = value[name] }
            profile.is_unmessagable = value.is_unmessagable if value.has_is_unmessagable?
          when 'config', 'module_config'
            klass, types, container = section == 'config' ? [Meshtastic::Config, CONFIG_TYPES, Meshtastic::LocalConfig] : [Meshtastic::ModuleConfig, MODULE_TYPES, Meshtastic::LocalModuleConfig]
            field = klass.descriptor.to_a[types.index(slot.to_sym)].name
            raise ArgumentError, 'protobuf section does not match slot' unless value.payload_variant.to_s == field

            profile[section] ||= container.new
            profile[section][field] = value[field]
          when 'channel'
            raise ArgumentError, 'channel index or role cannot round-trip in DeviceProfile' unless value.index == slot && value.role == (slot.zero? ? :PRIMARY : :SECONDARY) && value.settings

            channels << value
          when 'ringtone', 'canned_messages'
            profile[section] = value
          end
        end
        profile.channel_url = Admin::Channel.export_url(channels: channels, lora_config: profile.config&.lora) unless channels.empty?
        bytes = profile.to_proto.b
        count = profile_plan(bytes: bytes).length
        if opts[:path]
          File.open(opts[:path], File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
            file.binmode
            file.chmod(0o600)
            file.write(bytes)
            file.flush
            file.fsync
          end
        end
        { status: :exported, format: :device_profile, count: count, backup: bytes, warnings: [WARNING] }
      end

      private_class_method def self.profile_position(opts = {})
        value = opts[:value]
        raise ArgumentError unless value.is_a?(Hash) || value.is_a?(Meshtastic::Position)

        value = Meshtastic::Position.new(value) if value.is_a?(Hash)
        validate_wire(bytes: value.to_proto, descriptor: Meshtastic::Position.descriptor)
        Meshtastic::Position.decode(value.to_proto)
      rescue ArgumentError, TypeError, RangeError, Google::Protobuf::Error
        raise ArgumentError, 'fixed_position must be a valid Position protobuf or field Hash', cause: nil
      end

      public_class_method def self.import(opts = {})
        validate_options(options: opts, operation: :import)
        connection = connection_options(opts)
        raise ArgumentError, 'supply exactly one of path or backup' unless opts.key?(:path) ^ opts.key?(:backup)

        document = opts[:backup]
        if opts.key?(:path)
          document = File.open(opts[:path], File::RDONLY | File::NOFOLLOW) do |file|
            raise ArgumentError, 'backup path must be a regular file' unless file.stat.file?

            file.binmode
            file.read
          end
        end
        entries = import_plan(document: document, format: opts.fetch(:format, :auto), path: opts[:path])
        plan = entries.each_with_index.sort_by do |entry, index|
          priority = if entry[:section] == 'config'
                       { 'LORA_CONFIG' => 20, 'BLUETOOTH_CONFIG' => 21, 'NETWORK_CONFIG' => 22, 'SECURITY_CONFIG' => 23 }.fetch(entry[:slot], 0)
                     else
                       entry[:section] == 'channel' ? 10 : 0
                     end
          [priority, index]
        end.map(&:first)
        report = { status: :dry_run, planned: plan.length, attempted: 0, acknowledged: 0, readback_confirmed: 0, persistence_verified: false,
                   transaction: :not_requested, records: [], plan: plan.map { |entry| entry.slice(:section, :slot) }, warnings: [WARNING] }
        return report if opts.fetch(:dry_run, false)

        failure = nil
        if opts.fetch(:edit_transaction, false) && !plan.empty?
          failure = { operation: :begin_edit_settings }
          report[:transaction] = :begin_uncertain
          Admin.request(connection.merge(begin_edit_settings: true))
          report[:transaction] = :open
        end
        plan.each do |entry|
          field = { 'owner' => :set_owner, 'config' => :set_config, 'module_config' => :set_module_config,
                    'channel' => :set_channel, 'ui' => :store_ui_config, 'fixed_position' => :set_fixed_position,
                    'ringtone' => :set_ringtone_message, 'canned_messages' => :set_canned_message_module_messages }.fetch(entry[:section])
          failure = entry.slice(:section, :slot).merge(operation: field)
          report[:attempted] += 1
          status = apply_entry(connection: connection, field: field, entry: entry, failure: failure)
          report[status] += 1
          report[:records] << entry.slice(:section, :slot).merge(status: status)
        end
        if report[:transaction] == :open
          failure = { operation: :commit_edit_settings }
          report[:transaction] = :commit_uncertain
          Admin.request(connection.merge(commit_edit_settings: true))
          report[:transaction] = :commit_acknowledged
        end
        report[:status] = report[:readback_confirmed].positive? ? :applied : :acknowledged
        verify_readback(connection: connection, plan: plan, report: report) if opts.fetch(:verify, false)
        report
      rescue StandardError => e
        raise unless failure

        report[:status] = :partial_failure
        report[:failure] = failure.merge(error: e.class.name)
        report[:failure][:reason] = e.reason if e.is_a?(Admin::RoutingError)
        report
      end

      # A timed-out mutation is never resent; only a fresh getter can resolve it.
      private_class_method def self.apply_entry(opts = {})
        entry = opts[:entry]
        Admin.request(opts[:connection].merge(opts[:field] => entry[:message]))
        :acknowledged
      rescue Timeout::Error
        command = read_command(entry)
        opts[:failure][:readback] = :unsupported
        raise unless command

        opts[:failure][:readback] = :failed
        actual = Admin.request(opts[:connection].merge(command))[:value]
        opts[:failure][:readback] = :mismatch
        raise unless readback_matches?(entry: entry, actual: actual)

        :readback_confirmed
      end

      private_class_method def self.import_plan(opts = {})
        document = opts[:document]
        format = opts[:format]
        if format == :auto
          format = :json if document.is_a?(Hash) || File.extname(opts[:path].to_s).downcase == '.json'
          format = :device_profile if File.extname(opts[:path].to_s).downcase == '.cfg'
        end
        return profile_plan(bytes: document) if format == :device_profile

        if format == :auto
          begin
            return profile_plan(bytes: document)
          rescue ArgumentError
            raise unless document.is_a?(String) && document.b.lstrip.start_with?('{', '[')
          end
        end
        document = JSON.parse(document, object_class: StrictObject, allow_duplicate_key: false) if document.is_a?(String)
        validate_document(document: document)
      rescue JSON::ParserError
        raise ArgumentError, 'invalid backup JSON', cause: nil
      end

      # Protobuf decoding alone silently accepts unknown tags and last-wins duplicates.
      private_class_method def self.validate_wire(opts = {})
        bytes = opts[:bytes]
        descriptor = opts[:descriptor]
        depth = opts.fetch(:depth, 0)
        raise ArgumentError, 'invalid protobuf size or nesting' unless bytes.is_a?(String) && bytes.bytesize <= 1_048_576 && depth <= 32

        stream = StringIO.new(bytes.b)
        fields = descriptor.to_h { |field| [field.number, field] }
        oneofs = {}
        descriptor.each_oneof { |oneof| oneof.each { |field| oneofs[field.number] = oneof.name } }
        seen = []
        until stream.eof?
          tag = wire_varint(stream: stream)
          field = fields[tag >> 3]
          raise ArgumentError, 'unknown protobuf field' unless field

          identity = oneofs.fetch(field.number, field.number)
          raise ArgumentError, 'duplicate protobuf field or conflicting oneof' if field.label != :repeated && seen.include?(identity)

          seen << identity
          wire = tag & 7
          expected = case field.type
                     when :double, :fixed64, :sfixed64 then 1
                     when :string, :bytes, :message then 2
                     when :float, :fixed32, :sfixed32 then 5
                     else 0
                     end
          packed = field.label == :repeated && wire == 2 && expected != 2
          raise ArgumentError, 'invalid protobuf wire type' unless wire == expected || packed

          if wire == 2
            length = wire_varint(stream: stream)
            raise ArgumentError, 'truncated protobuf field' if length > stream.size - stream.pos

            payload = stream.read(length)
            if field.type == :message
              validate_wire(bytes: payload, descriptor: field.subtype, depth: depth + 1)
            elsif packed
              packed_stream = StringIO.new(payload)
              wire_scalar(stream: packed_stream, field: field, wire: expected) until packed_stream.eof?
            end
          else
            wire_scalar(stream: stream, field: field, wire: wire)
          end
        end
      end

      private_class_method def self.wire_varint(opts = {})
        value = 0
        10.times do |index|
          byte = opts[:stream].getbyte
          raise ArgumentError, 'invalid protobuf varint' if byte.nil? || (index == 9 && byte > 1)

          value |= (byte & 127) << (index * 7)
          next unless byte < 128

          raise ArgumentError, 'noncanonical protobuf varint' if index.positive? && byte.zero?

          return value
        end
        raise ArgumentError, 'invalid protobuf varint'
      end

      private_class_method def self.wire_scalar(opts = {})
        stream = opts[:stream]
        field = opts[:field]
        if opts[:wire].zero?
          value = wire_varint(stream: stream)
          invalid = field.type == :bool && value > 1
          invalid ||= %i[uint32 sint32].include?(field.type) && value > 0xffffffff
          invalid ||= %i[int32 enum].include?(field.type) && value > 0x7fffffff && value < 0xffffffff80000000
          if field.type == :enum
            signed = value >= 0x8000000000000000 ? value - 0x10000000000000000 : value
            invalid ||= field.subtype.lookup_value(signed).nil?
          end
          raise ArgumentError, 'invalid protobuf scalar or unknown enum' if invalid
        else
          length = opts[:wire] == 1 ? 8 : 4
          bytes = stream.read(length)
          raise ArgumentError, 'truncated protobuf scalar' unless bytes && bytes.bytesize == length
          raise ArgumentError, 'nonfinite protobuf float' if %i[float double].include?(field.type) && !bytes.unpack1(length == 4 ? 'e' : 'E').finite?
        end
      end

      private_class_method def self.profile_plan(opts = {})
        validate_wire(bytes: opts[:bytes], descriptor: Meshtastic::DeviceProfile.descriptor)
        profile = Meshtastic::DeviceProfile.decode(opts[:bytes])
        entries = []
        owner = (OWNER_FIELDS + ['is_unmessagable']).select { |name| profile.public_send("has_#{name}?") }
        unless owner.empty?
          values = owner.to_h { |name| [name.to_sym, profile[name]] }
          entries << { section: 'owner', slot: nil, message: Meshtastic::User.new(values), owner_fields: owner }
        end
        %w[fixed_position ringtone canned_messages].each do |name|
          entries << { section: name, slot: nil, message: profile[name] } if profile.public_send("has_#{name}?")
        end
        [[profile.config, Meshtastic::Config, CONFIG_TYPES, 'config'],
         [profile.module_config, Meshtastic::ModuleConfig, MODULE_TYPES, 'module_config']].each do |local, klass, types, section|
          next unless local

          klass.descriptor.to_a.take(types.length).each_with_index do |field, index|
            value = local[field.name]
            next unless value

            entries << { section: section, slot: types[index].to_s, message: klass.new(field.name.to_sym => value) }
          end
        end
        if profile.has_channel_url?
          uri = URI.parse(profile.channel_url)
          raise ArgumentError, 'channel URL queries are unsupported' if uri.query

          channel_set = Admin::Channel.import_url(url: profile.channel_url)
          payload = Base64.urlsafe_decode64(uri.fragment)
          raise ArgumentError, 'noncanonical channel URL base64' unless Base64.urlsafe_encode64(payload, padding: false) == uri.fragment.delete_suffix('==').delete_suffix('=')

          validate_wire(bytes: payload, descriptor: Meshtastic::ChannelSet.descriptor)
          channel_set.settings.each_with_index do |settings, index|
            channel = Admin::Channel.build(index: index, role: index.zero? ? :PRIMARY : :SECONDARY, settings: settings)
            entries << { section: 'channel', slot: index, message: channel }
          end
          if channel_set.lora_config
            lora = entries.find { |entry| entry[:section] == 'config' && entry[:slot] == 'LORA_CONFIG' }
            message = Meshtastic::Config.new(lora: channel_set.lora_config)
            raise ArgumentError, 'conflicting profile and channel URL LoRa configuration' if lora && lora[:message] != message

            entries << { section: 'config', slot: 'LORA_CONFIG', message: message } unless lora
          end
        end
        raise ArgumentError, 'DeviceProfile contains no restorable fields' if entries.empty?

        entries
      rescue Google::Protobuf::ParseError, TypeError, RangeError, URI::InvalidURIError
        raise ArgumentError, 'invalid DeviceProfile protobuf or channel URL', cause: nil
      end

      private_class_method def self.verify_readback(opts = {})
        report = opts[:report]
        report[:readback_matched] = 0
        opts[:plan].each_with_index do |entry, index|
          command = read_command(entry)
          unless command
            report[:records][index][:readback] = :unsupported
            next
          end
          actual = Admin.request(opts[:connection].merge(command))[:value]
          matched = readback_matches?(entry: entry, actual: actual)
          report[:records][index][:readback] = matched ? :matched : :mismatch
          report[:readback_matched] += 1 if matched
        rescue StandardError => e
          report[:records][index][:readback] = :failed
          report[:records][index][:readback_error] = e.class.name
        end
        report[:status] = report[:readback_matched] == opts[:plan].length ? :readback_matched : :readback_incomplete
      end

      private_class_method def self.readback_matches?(opts = {})
        entry = opts[:entry]
        actual = opts[:actual]
        if entry[:section] == 'owner'
          fields = entry.fetch(:owner_fields, OWNER_FIELDS).select do |name|
            !Meshtastic::User.descriptor.lookup(name).has_presence? || actual.public_send("has_#{name}?")
          end
          actual = Meshtastic::User.new(fields.to_h { |name| [name.to_sym, actual[name]] })
        end
        actual == entry[:message]
      end

      private_class_method def self.validate_document(opts = {})
        document = opts[:document]
        raise ArgumentError, 'invalid backup document or version' unless document.is_a?(Hash) && document.keys.sort == %w[format records version warning] && document['format'] == FORMAT && document['version'].is_a?(Integer) && document['version'] == 1 && document['warning'].is_a?(String) && document['records'].is_a?(Array)

        seen = []
        document['records'].map do |record|
          raise ArgumentError, 'invalid backup record' unless record.is_a?(Hash) && record.keys.sort == %w[section slot value]

          section = record['section']
          slot = record['slot']
          identity = [section, slot]
          raise ArgumentError, 'duplicate backup slot' if seen.include?(identity)

          seen << identity
          klass = case section
                  when 'owner'
                    raise ArgumentError, 'invalid owner slot or identity fields' unless slot.nil? && record['value'].is_a?(Hash) && (record['value'].keys - OWNER_FIELDS).empty?

                    Meshtastic::User
                  when 'config'
                    raise ArgumentError, 'invalid config slot' unless CONFIG_TYPES.map(&:to_s).include?(slot)

                    Meshtastic::Config
                  when 'module_config'
                    raise ArgumentError, 'invalid module slot' unless MODULE_TYPES.map(&:to_s).include?(slot)

                    Meshtastic::ModuleConfig
                  when 'channel'
                    raise ArgumentError, 'invalid channel slot' unless slot.is_a?(Integer) && slot.between?(0, 7)

                    Meshtastic::Channel
                  when 'ui'
                    raise ArgumentError, 'invalid UI slot' unless slot.nil?

                    Meshtastic::DeviceUIConfig
                  else
                    raise ArgumentError, 'unknown backup section'
                  end
          validate_proto_json(value: record['value'], descriptor: klass.descriptor)
          message = klass.decode_json(JSON.generate(record['value']), ignore_unknown_fields: false)
          if %w[config module_config].include?(section)
            types = section == 'config' ? CONFIG_TYPES : MODULE_TYPES
            fields = klass.descriptor.map(&:name)
            expected = fields[types.index(slot.to_sym)]
            raise ArgumentError, 'protobuf section does not match slot' unless message.payload_variant.to_s == expected
          end
          raise ArgumentError, 'channel index does not match slot' if section == 'channel' && message.index != slot

          { section: section, slot: slot, message: message }
        end
      rescue Google::Protobuf::ParseError, TypeError, RangeError
        raise ArgumentError, 'invalid protobuf JSON in backup'
      end

      private_class_method def self.validate_proto_json(opts = {})
        value = opts[:value]
        descriptor = opts[:descriptor]
        raise ArgumentError, 'protobuf value must be an object' unless value.is_a?(Hash)

        value.each do |name, item|
          field = descriptor.lookup(name) if name.is_a?(String)
          raise ArgumentError, 'unknown protobuf field' unless field
          raise ArgumentError, 'null protobuf values are not supported' if item.nil?

          items = field.label == :repeated ? item : [item]
          raise ArgumentError, 'repeated protobuf field must be an array' unless items.is_a?(Array)

          items.each do |entry|
            validate_proto_json(value: entry, descriptor: field.subtype) if field.type == :message
            next unless field.type == :bytes

            raise ArgumentError, 'bytes must use canonical base64' unless entry.is_a?(String) && Base64.strict_encode64(Base64.strict_decode64(entry)) == entry
          end
        end
      end

      private_class_method def self.validate_options(opts = {})
        options = opts[:options]
        allowed = %i[transport_obj to timeout channel hop_limit path]
        allowed += opts[:operation] == :export ? %i[format config_types module_config_types channel_indexes include_owner include_ui] : %i[backup format dry_run edit_transaction verify]
        allowed += %i[fixed_position include_ringtone include_canned_messages] if opts[:operation] == :export && options[:format] == :device_profile
        raise ArgumentError, 'unknown backup options' unless (options.keys - allowed).empty?

        formats = opts[:operation] == :export ? %i[json device_profile] : %i[auto json device_profile]
        raise ArgumentError, "format must be one of #{formats.join(', ')}" if options.key?(:format) && !formats.include?(options[:format])

        %i[include_owner include_ui include_ringtone include_canned_messages dry_run edit_transaction verify].each do |key|
          raise ArgumentError, 'backup flags must be boolean' if options.key?(key) && ![true, false].include?(options[key])
        end
        timeout = options.fetch(:timeout, 10)
        raise ArgumentError, 'timeout must be positive and finite' unless timeout.is_a?(Numeric) && timeout.positive? && timeout.finite?
      end

      private_class_method def self.connection_options(opts = {})
        raise ArgumentError, 'MQTT synchronous backup is unsupported' if Admin.transport_type(opts) == :mqtt

        opts.slice(:transport_obj, :to, :timeout, :channel, :hop_limit)
      end

      private_class_method def self.selection(opts = {})
        configs = opts.fetch(:config_types, CONFIG_TYPES)
        modules = opts.fetch(:module_config_types, [])
        channels = opts.fetch(:channel_indexes, (0..7).to_a)
        raise ArgumentError, 'invalid config_types' unless configs.is_a?(Array) && (configs - CONFIG_TYPES).empty? && configs.uniq == configs
        raise ArgumentError, 'invalid module_config_types' unless modules.is_a?(Array) && (modules - MODULE_TYPES).empty? && modules.uniq == modules
        raise ArgumentError, 'invalid channel_indexes' unless channels.is_a?(Array) && channels.all? { |i| i.is_a?(Integer) && i.between?(0, 7) } && channels.uniq == channels

        records = []
        records << ['owner', nil] if opts.fetch(:include_owner, true)
        configs.each { |type| records << ['config', type.to_s] }
        modules.each { |type| records << ['module_config', type.to_s] }
        channels.each { |index| records << ['channel', index] }
        records << ['ui', nil] if opts.fetch(:include_ui, false)
        records << ['ringtone', nil] if opts.fetch(:include_ringtone, false)
        records << ['canned_messages', nil] if opts.fetch(:include_canned_messages, false)
        records
      end

      private_class_method def self.read_command(opts = {})
        case opts[:section]
        when 'owner' then { get_owner_request: true }
        when 'config' then { get_config_request: opts[:slot].to_sym }
        when 'module_config' then { get_module_config_request: opts[:slot].to_sym }
        when 'channel' then { get_channel_request: opts[:slot] + 1 }
        when 'ui' then { get_ui_config_request: true }
        when 'ringtone' then { get_ringtone_request: true }
        when 'canned_messages' then { get_canned_message_module_messages_request: true }
        end
      end

      public_class_method def self.authors
        "AUTHOR(S):\n        0day Inc. <support@0dayinc.com>\n"
      end

      public_class_method def self.help
        puts "USAGE:
          # Export fresh selected configuration sections.
          #{self}.export(
            transport_obj: 'required - connected Serial, Bluetooth or TCP handle',
            format: 'optional - :json (default version-1 Hash) or :device_profile (binary String in result[:backup]); result also has status, count and warnings',
            path: 'optional - new secret JSON or binary .cfg file matching format; never overwritten; mode 0600',
            to: 'optional - explicit unicast target; defaults to local node',
            timeout: 'optional - positive finite per-request seconds; default 10',
            config_types: 'optional - ConfigType symbols; default eight writable core sections',
            module_config_types: 'optional - ModuleConfigType symbols; default empty',
            channel_indexes: 'optional - unique zero-based indexes 0 through 7; default all eight; binary requires contiguous prefix from 0 with PRIMARY then SECONDARY roles, no disabled slots',
            include_owner: 'optional - portable owner names and license flag; binary also preserves present is_unmessagable; default true',
            include_ui: 'optional - dedicated UI configuration; default false; true is rejected for binary before requests',
            fixed_position: 'optional - binary only: explicit Position protobuf or field Hash; no getter exists; omitted by default',
            include_ringtone: 'optional - binary only: fresh ringtone including empty string; boolean default false',
            include_canned_messages: 'optional - binary only: fresh canned messages including empty string; boolean default false',
            channel: 'optional - mesh transport channel index; default Admin behavior',
            hop_limit: 'optional - mesh transport hop limit; default Admin behavior'
          )
          # Restore with bounded ACKs or exact timeout readback; never replay writes.
          #{self}.import(
            transport_obj: 'required - connected Serial, Bluetooth or TCP handle; no MQTT',
            path: 'optional - existing JSON or binary DeviceProfile .cfg file; mutually exclusive with backup',
            backup: 'optional - versioned JSON Hash, JSON String or binary DeviceProfile String; mutually exclusive with path',
            format: 'optional - :auto (default), :json or :device_profile; cfg paths select binary, other content is validated',
            dry_run: 'optional - validate and plan without any radio requests; default false',
            edit_transaction: 'optional - begin/commit on firmware known to support edits; default false',
            verify: 'optional - additional fresh comparison after completed writes/commit; timeout recovery reads occur regardless; not durability proof; default false',
            timeout: 'optional - positive finite seconds per request; default 10',
            to: 'optional - explicit unicast target; defaults to connected local node',
            channel: 'optional - mesh transport channel index; default Admin behavior',
            hop_limit: 'optional - mesh transport hop limit; default Admin behavior'
          )
          # Contains secrets; firmware may redact values. Never logs document contents.
          # Display the module authors.
          #{self}.authors
        "
      end
    end
  end
end
