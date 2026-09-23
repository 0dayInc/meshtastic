# frozen_string_literal: true

module Meshtastic
  # Default-preset Unishox2, translated from siara-cc/Unishox2 (Apache-2.0),
  # revision 4981d9403de3bdd1938a635ab73f8a2c5a536059.
  # Copyright (C) 2020 Siara Logics (cc).
  # Authors: Arundale Ramanathan, James Z. M. Gao.
  # Ruby adaptation changes: default preset only, bounded strings, strict
  # UTF-8/back-reference validation and explicit malformed-code errors.
  # Apache-2.0 license text is included after __END__ below.
  # No native decoder receives untrusted input. Output and input are bounded.
  module Unishox2
    MAX_DECODED = 4096

    public_class_method def self.decode(opts = {})
      Decoder.new(opts.fetch(:payload).to_s.b).decode
    end

    public_class_method def self.authors
      'Unishox2: Arundale Ramanathan, James Z. M. Gao (Apache-2.0); Ruby adaptation: Meshtastic contributors'
    end

    public_class_method def self.help
      puts "USAGE:
        # Decode default-preset Unishox2 compressed text.
        #{self}.decode(payload: 'required - compressed bytes, maximum 4096 decoded bytes')
        # Report codec implementation authors.
        #{self}.authors
      "
    end

    class DecoderState
      V_CODES = %w[00 010 011 1000 1001 1010 1011 1100 11010 11011 111000 111001 111010 1110110 1110111 1111000 1111001 1111010 11110110 11110111 11111000 11111001 11111010 11111011 11111100 11111101 11111110 11111111].freeze
      H_CODES = %w[00 01 10 110 111].freeze
      SETS = ["\0 etaoinsrlcdhupmbgwfyvkqjxz", "\"{}_<>:\n\0[]\\;'\t@*&?!^|\r~`\0\0\0", "\0,.01925-/34678() =+$%#\0\0\0\0\0"].map(&:bytes).freeze
      FREQUENCIES = ['": "', '": ', '</', '="', '":"', '://'].freeze
      TEMPLATES = ['tfff-of-tfTtf:rf:rf.fffZ', 'tfff-of-tf', '(fff) fff-ffff', 'tf:rf:rf'].freeze
      class EndOfBits < StandardError; end

      def initialize(bytes)
        raise ArgumentError, 'Unishox2 input exceeds 4096 bytes' if bytes.bytesize > MAX_DECODED
        raise ArgumentError, 'invalid Unishox2 magic bit' if !bytes.empty? && bytes.getbyte(0) < 128

        @bits = bytes.unpack1('B*')
        @pos = bytes.empty? ? 0 : 1
        @out = +''.b
        @state = @h = 0
        @upper = false
        @unicode = 0
      end

      def decode
        begin
          while @pos < @bits.length
            remaining = @bits[@pos..]
            terminator = { 0 => '001011111111', 2 => '11111111', 4 => '11111101011111111' }.fetch(@state)
            # Default encoder truncates the terminator to the last byte.
            break if remaining.length < 8 && terminator.start_with?(remaining) && !(@h == 4 && @state != 4)

            decode_symbol
          end
        rescue EndOfBits
          raise ArgumentError, 'truncated Unishox2 code (not terminator padding)'
        end
        text = @out.force_encoding(Encoding::UTF_8)
        raise ArgumentError, 'invalid UTF-8 in Unishox2 text' unless text.valid_encoding?

        text
      end

      private

      def bits(count)
        raise EndOfBits if @pos + count > @bits.length

        value = @bits[@pos, count].to_i(2)
        @pos += count
        value
      end

      def code(codes)
        index = codes.index { |word| @bits[@pos, word.length] == word }
        raise EndOfBits unless index

        @pos += codes[index].length
        index
      end

      def step(limit)
        index = 0
        index += 1 while index < limit && bits(1) == 1
        index
      end

      def count
        index = step(4)
        bits([2, 4, 7, 11, 16][index]) + [0, 4, 20, 148, 2196][index]
      end

      def append(value)
        value = value.chr(Encoding::BINARY) if value.is_a?(Integer)
        raise ArgumentError, 'Unishox2 decoded output exceeds 4096 bytes' if @out.bytesize + value.bytesize > MAX_DECODED

        @out << value.b
      end

      def repeat
        length = count + 5
        distance = count + 4
        raise ArgumentError, 'invalid Unishox2 back-reference' if distance > @out.bytesize || length > distance

        append(@out.byteslice(@out.bytesize - distance, length))
      end

      def alpha_shift
        if @upper
          @upper = false
          return [0, false, true]
        end
        vertical = code(V_CODES)
        if vertical.zero?
          @h = code(H_CODES)
          if @h.zero?
            @upper = true
            return [0, false, true]
          end
        end
        [vertical, true, false]
      end
    end

    class Decoder < DecoderState
      private

      def unicode?
        index = step(5)
        if index == 5
          special = step(4)
          if special == 1
            @h = code(H_CODES)
            if [0, 4].include?(@h)
              @state = @h
              return true
            end
            if @h == 3
              repeat
              @h = @state
              return true
            end
            return false
          end
          append({ 0 => ' ', 2 => ',', 3 => '.', 4 => "\n" }.fetch(special))
          return true
        end
        sign = bits(1)
        delta = bits([6, 12, 14, 16, 21][index]) + [0, 64, 4160, 20_544, 86_080][index]
        @unicode += sign == 1 ? -delta : delta
        raise ArgumentError, 'invalid Unishox2 Unicode codepoint' unless @unicode.between?(128, 0x10ffff) && !@unicode.between?(0xd800, 0xdfff)

        append([@unicode].pack('U'))
        true
      end

      def nibble_block
        kind = step(5)
        if kind.zero?
          template = TEMPLATES[step(4)]
          raise ArgumentError, 'invalid Unishox2 template' unless template

          length = template.length - count
          raise ArgumentError, 'invalid Unishox2 template length' if length.negative?

          template[0, length].each_char do |char|
            width = { 'f' => 4, 'F' => 4, 'r' => 3, 't' => 2, 'o' => 1 }[char]
            append(if width
                     bits(width).to_s(16).public_send(char == 'f' ? :downcase : :upcase)
                   else
                     char
                   end)
          end
        elsif kind == 5
          length = count
          raise ArgumentError, 'invalid Unishox2 binary length' if length.zero?

          length.times { append(bits(8)) }
        else
          uuid = [2, 4].include?(kind)
          length = uuid ? 32 : count
          raise ArgumentError, 'invalid Unishox2 hex length' if length.zero?

          length.downto(1) do |remaining|
            char = bits(4).to_s(16)
            append(kind < 3 ? char : char.upcase)
            append('-') if uuid && [25, 21, 17, 13].include?(remaining)
          end
        end
        @h = 4 if @state == 4
      end

      def decode_symbol
        if @state == 4 || @h == 4
          @h = @state unless @state == 4
          return if unicode?
        else
          @h = @state
        end
        upper = @upper
        vertical = code(V_CODES)
        if vertical.zero? && @h != 1
          @h = code(H_CODES) unless @h == 2 && @state == 4
          if @h.zero?
            if @state.zero?
              vertical, upper, finished = alpha_shift
              return if finished
            else
              @state = 0
              return
            end
          elsif @h == 3
            repeat
            return
          elsif @h == 4
            return
          else
            vertical = code(V_CODES) unless @h == 2 && @state == 4
            return nibble_block if @h == 2 && vertical.zero?
          end
        end
        if upper && vertical == 1
          @state = @h = 4
          return
        end
        char = @h < 3 ? SETS[@h][vertical] : 0
        if char.between?(97, 122)
          @state = 0
          char -= 32 if upper
        elsif char.between?(48, 57)
          @state = 2
        elsif char.zero?
          if vertical == 8
            append("\r\n")
          elsif @h == 2 && vertical == 26
            length = count + 4
            raise ArgumentError, 'invalid Unishox2 repeat' if @out.empty?
            raise ArgumentError, 'Unishox2 decoded output exceeds 4096 bytes' if @out.bytesize + length > MAX_DECODED

            append(@out.byteslice(-1, 1) * length)
          elsif @h == 1 && vertical > 24
            append(FREQUENCIES[vertical - 25])
          elsif @h == 2 && vertical.between?(23, 25)
            append(FREQUENCIES[vertical - 20])
          else
            @pos = @bits.length
          end
          @h = 4 if @state == 4
          return
        end
        @h = 4 if @state == 4
        append(char)
      end
    end
    private_constant :Decoder, :DecoderState
  end
end

__END__
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2019 Siara Logics (cc)

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
