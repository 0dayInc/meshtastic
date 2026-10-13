# frozen_string_literal: true

require 'openssl'

# Independent test-only CBC-MAC/CTR reference, not OpenSSL's CCM implementation.
# Layout from firmware 8e6a88d06f44cad26f1e8d7cd402939ccacb9b4c
# src/mesh/aes-ccm.cpp (L=2). The specs validate this against its RFC3610 vector.
module ChannelCryptoReference
  def self.encrypt(key:, nonce:, aad:, plain:, tag_len: 12)
    ecb = OpenSSL::Cipher.new("aes-#{key.bytesize * 8}-ecb")
    ecb.encrypt
    ecb.padding = 0
    ecb.key = key
    encrypt = ->(block) { ecb.update(block) }
    xor = ->(left, right) { left.bytes.zip(right.bytes).map { |x, y| x ^ y }.pack('C*') }
    b0 = [0x40 | (((tag_len - 2) / 2) << 3) | 1].pack('C') + nonce + [plain.bytesize].pack('n')
    mac = encrypt.call(b0)
    [[aad.bytesize].pack('n') + aad, plain].each do |bytes|
      bytes = bytes.ljust((bytes.bytesize + 15) / 16 * 16, "\0")
      bytes.bytes.each_slice(16) { |block| mac = encrypt.call(xor.call(mac, block.pack('C*'))) }
    end
    ctr = ->(index) { encrypt.call("\1#{nonce}#{[index].pack('n')}") }
    tag = xor.call(mac, ctr.call(0))[0, tag_len]
    crypt = plain.bytes.each_slice(16).with_index.map do |block, index|
      xor.call(block.pack('C*'), ctr.call(index + 1)[0, block.size])
    end.join
    crypt + tag
  end
end
