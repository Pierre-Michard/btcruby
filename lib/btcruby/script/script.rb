module BTC
  class Script
    include Opcodes
    
    # Serialized binary form of the script (payload)
    attr_reader :data

    # List of public keys if it is a multisig script.
    # If it is not a multisig script, returns nil.
    # See also #multisig_script?
    attr_reader :multisig_public_keys

    # Number of signatures required if it is a multisig script.
    # If it is not a multisig script, returns nil.
    # See also #multisig_script?
    attr_reader :multisig_signatures_required
    
    # Returns an array of chunks that constitute the script.
    attr_reader :chunks

    def initialize(hex: nil, # raw script data in hex
                   data: nil, # raw script data in binary
                   op_return: nil, # binary string for OP_RETURN script (or array of binary string)
                   public_keys: nil, signatures_required: nil # multisig
                   )
      if data || hex
        data ||= BTC.from_hex(hex)
        data = BTC::Data.ensure_binary_encoding(data)
        @chunks = []
        offset = 0
        while offset < data.bytesize
          chunk = ScriptChunk.with_data(data, offset: offset)
          if !chunk.canonical?
            Diagnostics.current.add_message("BTC::Script: decoded non-canonical chunk at offset #{offset}: #{chunk.to_s}")
          end
          offset += chunk.size
          @chunks << chunk
        end
      elsif op_return
        @chunks = []
        self << OP_RETURN << op_return
      elsif public_keys || signatures_required
        if !public_keys || public_keys.size < 1
          raise ArgumentError, "Public keys must be an array of at least 1 pubkey"
        end
        if !signatures_required || signatures_required < 1
          raise ArgumentError, "Number of required signatures must be greater than zero"
        end
        if signatures_required > public_keys.size
          raise ArgumentError, "Number of required signatures must not exceed number of pubkeys."
        end
        if public_keys.size > 16
          raise ArgumentError, "Maximum number of public keys exceeded (16)"
        end

        n_opcode = Opcode.opcode_for_small_integer(public_keys.size)
        m_opcode = Opcode.opcode_for_small_integer(signatures_required)

        @chunks = []
        self << m_opcode << public_keys << n_opcode << OP_CHECKMULTISIG
      else
        # Empty script
        @chunks = []
      end
    end

    # Initializes a multisignature script "OP_<M> <pubkey1> ... <pubkeyN> OP_<N> OP_CHECKMULTISIG"
    # N must be >= M, M and N should be from 1 to 16.
    # If you need a more customized transaction with OP_CHECKMULTISIG, create it using other methods.
    # `public_keys` is an array of binary strings.
    def self.multisig(public_keys: [], signatures_required: 0)
      self.new(public_keys: public_keys, signatures_required: signatures_required)
    end


    # Representation and conversion
    # -----------------------------

    # Returns true if this is a standard script
    # As of September 2014, standard = public_key_hash_script? ||
    #                                  p2sh_script? ||
    #                                  standard_multisig_script? ||
    #                                  public_key_script? ||
    #                                  standard_op_return_script?
    def standard?
      public_key_hash_script? ||
      script_hash_script? ||
      standard_multisig_script? ||
      public_key_script? ||
      standard_op_return_script?
    end

    # Returns true if the script is a pay-to-pubkey script:
    # "<pubkey> OP_CHECKSIG"
    def public_key_script?
      return false if @chunks.size != 2
      return @chunks[0].pushdata? &&
             @chunks[0].pushdata.size >= 33 &&
             @chunks[1].opcode == OP_CHECKSIG
    end

    def p2pk?
      return public_key_script?
    end

    # Returns a raw public key if this script is public_key_script?
    def public_key
      @chunks[0] && @chunks[0].pushdata
    end

    # Returns true if the script is a P2PKH script:
    # "OP_DUP OP_HASH160 <20-byte hash> OP_EQUALVERIFY OP_CHECKSIG"
    def public_key_hash_script?
      return false if @chunks.size != 5
      return @chunks[0].opcode == OP_DUP &&
             @chunks[1].opcode == OP_HASH160 &&
             @chunks[2].size == 21 &&
             @chunks[3].opcode == OP_EQUALVERIFY &&
             @chunks[4].opcode == OP_CHECKSIG
    end

    def p2pkh?
      return public_key_hash_script?
    end

    # Returns public key hash if this script is public_key_hash_script?
    def public_key_hash
      @chunks[2] && @chunks[2].pushdata
    end

    # Returns true if the script is a P2SH script:
    # "OP_HASH160 <20-byte hash> OP_EQUAL"
    def script_hash_script?
      return false if @chunks.size != 3
      return @chunks[0].opcode == OP_HASH160 &&
             @chunks[1].size == 21 &&
             @chunks[2].opcode == OP_EQUAL
    end

    def p2sh?
      return script_hash_script?
    end

    # Returns p2sh hash if this script is script_hash_script?
    def script_hash
      @chunks[1] && @chunks[1].pushdata
    end

    # Returns true if the script is "OP_<M> <pubkey1> ... <pubkeyN> OP_<N> OP_CHECKMULTISIG"
    # where N is up to 15.
    # Scripts with up to 15 signatures are considered standard and relayed quickly,
    # but you are allowed to create more complex ones.
    def standard_multisig_script?
      return false if !multisig_script?

      # Check chunks directly so we make sure OP_<N> are used, not pushdata.
      # Bitcoin allows encoding multisig N and M parameters as pushdata
      # (which will be interpreted as a little-endian bignum)
      m_opcode = @chunks[0].opcode
      n_opcode = @chunks[-2].opcode
      if n_opcode >= OP_1 && n_opcode <= OP_15
        if m_opcode >= OP_1 && m_opcode <= n_opcode
          return true
        end
      end
      return false
    end

    # Returns true if the script is in form "<M> <pubkey1> ... <pubkeyN> <N> OP_CHECKMULTISIG"
    def multisig_script?
      detect_multisig_if_needed
      @is_multisig
    end

    # List of public keys if it is a multisig script.
    # If it is not a multisig script, returns nil.
    # See also #multisig_script?
    def multisig_public_keys
      detect_multisig_if_needed
      @multisig_public_keys
    end

    # Number of signatures required if it is a multisig script.
    # If it is not a multisig script, returns nil.
    # See also #multisig_script?
    def multisig_signatures_required
      detect_multisig_if_needed
      @multisig_signatures_required
    end

    # Returns true if this script is a 'OP_RETURN <data>' script and
    # data size is within 40 bytes.
    def standard_op_return_script?
      retun false if !op_return_data_only_script? || @chunks.size != 2
      @chunks[1].pushdata.bytesize <= 40
    end

    # Returns true if this script's first opcode is OP_RETURN.
    def op_return_script?
      return @chunks.size >= 1 &&
             @chunks[0].opcode == OP_RETURN
    end
    
    # Returns true if this script is of form 'OP_RETURN <data>'
    def op_return_data_only_script?
      return @chunks.size >= 2 &&
             @chunks[0].opcode == OP_RETURN &&
             @chunks[1..-1].all?{|c| c.pushdata? }
    end

    # Returns first data chunk if this script is 'OP_RETURN <data>'.
    # Otherwise returns nil.
    def op_return_data
      return nil if !op_return_data_only_script?
      return @chunks[1].pushdata
    end

    # Returns all data chunks if this script is 'OP_RETURN <data> [<data>...]'
    # Most commonly returned array contains one binary string.
    def op_return_items
      return nil if !op_return_data_only_script?
      return @chunks[1, @chunks.size-1].map{|c| c.pushdata}
    end

    # Returns `true` if this script may be a valid OpenAssets marker.
    # Only checks the prefix and minimal length, does not validate the content.
    # Use this method to quickly filter out non-asset transactions.
    def open_assets_marker?
      return false if !op_return_data_only_script?
      data = op_return_data
      return false if !data || data.bytesize < 6
      if data[0, AssetMarker::PREFIX_V1.bytesize] == AssetMarker::PREFIX_V1
        return true
      end
      false
    end

    # Returns pushdata if script starts with <pushdata> OP_DROP
    # Returns nil if the script starts with some other opcodes or shorter than 2 opcodes.
    def dropped_prefix_data
      if @chunks.size >= 2 && @chunks[0].pushdata? && @chunks[1].opcode == OP_DROP
        return @chunks[0].pushdata
      end
      nil
    end

    # If script starts with `<pushdata> OP_DROP`, these two opcodes are removed
    # and a new script instance is returned.
    def without_dropped_prefix_data
      if dropped_prefix_data
        return Script.new << @chunks[2..-1]
      end
      self
    end

    # Returns true if the script consists of push data operations only
    # (including OP_<N>). Aka isPushOnly in BitcoinQT.
    # Used in BIP16 (P2SH) implementation.
    def data_only?
      # Include PUSHDATA ops and OP_0..OP_16 literals.
      @chunks.each do |chunk|
        return false if !chunk.data_only?
      end
      return true
    end

    # Serialized binary form of the script (payload)
    def data
      @chunks.inject("".b){|buf,c| buf << c.raw_data}
    end

    # Human-readable textual representation of the script
    # (e.g. "OP_DUP OP_HASH160 5a73e920b7836c74f9e740a5bb885e8580557038 OP_EQUALVERIFY OP_CHECKSIG")
    def to_s
      @chunks.map{|c| c.to_s }.join(" ")
    end

    def to_hex
      BTC.to_hex(self.data)
    end

    # Returns an array of opcodes or pushdata strings.
    # Integers are opcodes, strings are pushdata binary strings.
    # OP_0 is treated as a zero-length pushdata.
    def to_a
      @chunks.map{|c| c.pushdata? ? c.pushdata : c.opcode }
    end

    # Complete copy of a script.
    def dup
      Script.new(data: self.data)
    end

    def ==(other)
      return false if other == nil
      self.data == other.data
    end
    alias_method :eql?, :==

    def inspect
      %{#<#{self.class.name} #{to_s.inspect} (#{self.data.bytesize} bytes)>}
    end



    # Conversion
    # ----------


    # Returns BTC::PublicKeyAddress or BTC::ScriptHashAddress if
    # the script is a standard output script for these addresses.
    # If the script is something different, returns nil.
    def standard_address(network: nil)
      if public_key_hash_script?
        return BTC::PublicKeyAddress.new(hash: @chunks[2].pushdata, network: network)
      elsif script_hash_script?
        return BTC::ScriptHashAddress.new(hash: @chunks[1].pushdata, network: network)
      elsif public_key_script?
        return BTC::PublicKeyAddress.new(hash: BTC.hash160(@chunks[0].pushdata), network: network)
      end
      nil
    end

    # Wraps the recipient into an output P2SH script
    # (OP_HASH160 <20-byte hash of the recipient> OP_EQUAL).
    def p2sh_script
      Script.new << OP_HASH160 << BTC.hash160(self.data) << OP_EQUAL
    end


    # Returns a dummy script matching this script on the input with
    # the same size as an intended signature script.
    # Only a few standard script types are supported.
    # Set `strict` to false to allow imprecise guess for P2SH script.
    # Returns nil if could not determine a matching script.
    def simulated_signature_script(strict: true)
      if public_key_hash_script?
         # assuming non-compressed pubkeys to be conservative
        return Script.new << Script.simulated_signature(hashtype: SIGHASH_ALL) << Script.simulated_uncompressed_pubkey

      elsif public_key_script?
        return Script.new << Script.simulated_signature(hashtype: SIGHASH_ALL)

      elsif script_hash_script? && !strict
        # This is a wild approximation, but works well if most p2sh scripts are 2-of-3 multisig scripts.
        # If you have a very particular smart contract scheme you should not use TransactionBuilder which estimates fees this way.
        return Script.new << OP_0 << [Script.simulated_signature(hashtype: SIGHASH_ALL)]*2 << Script.simulated_multisig_script(2,3).data

      elsif multisig_script?
        return Script.new << OP_0 << [Script.simulated_signature(hashtype: SIGHASH_ALL)]*self.multisig_signatures_required
      else
        return nil
      end
    end

    # Returns a simulated signature with an optional hashtype byte attached
    def self.simulated_signature(hashtype: nil)
      "\x30" + "\xff"*71 + (hashtype ? WireFormat.encode_uint8(hashtype) : "")
    end

    # Returns a dummy uncompressed pubkey (65 bytes).
    def self.simulated_uncompressed_pubkey
      "\x04" + "\xff"*64
    end

    # Returns a dummy compressed pubkey (33 bytes).
    def self.simulated_compressed_pubkey
      "\x02" + "\xff"*32
    end

    # Returns a dummy script that simulates m-of-n multisig script
    def self.simulated_multisig_script(m,n)
      self.new <<
        Opcode.opcode_for_small_integer(m) <<
        [simulated_uncompressed_pubkey]*n  << # assuming non-compressed pubkeys to be conservative
        Opcode.opcode_for_small_integer(n) <<
        OP_CHECKMULTISIG
    end


    # Modification
    # ------------

    # Appends a non-pushdata opcode to the script.
    def append_opcode(opcode)
      raise ArgumentError, "Invalid opcode value." if opcode > 0xff || opcode < 0
      if opcode > 0 && opcode <= OP_PUSHDATA4
        raise ArgumentError, "Cannot add pushdata opcode without data"
      end
      @chunks << ScriptChunk.new(opcode.chr)
      return self
    end

    # Appends a pushdata opcode with the most compact encoding.
    # Optional opcode may be equal to OP_PUSHDATA1, OP_PUSHDATA2, or OP_PUSHDATA4.
    # ArgumentError is raised if opcode does not represent a given data length.
    def append_pushdata(data, opcode: nil)
      raise ArgumentError, "No data provided" if !data
      encoded_pushdata = self.class.encode_pushdata(data, opcode: opcode)
      if !encoded_pushdata
        raise ArgumentError, "Cannot encode pushdata with opcode #{opcode}"
      end
      @chunks << ScriptChunk.new(encoded_pushdata)
      return self
    end

    # Removes all occurences of opcode. Typically it's OP_CODESEPARATOR.
    def delete_opcode(opcode)
      @chunks = @chunks.inject([]) do |list, chunk|
        list << chunk if chunk.opcode != opcode
        list
      end
      return self
    end

    # Removes all occurences of a given pushdata.
    def delete_pushdata(pushdata)
      @chunks = @chunks.inject([]) do |list, chunk|
        list << chunk if chunk.pushdata != pushdata
        list
      end
      return self
    end

    # Appends script to the current script.
    def append_script(script)
      raise ArgumentError, "No script is given" if !script
      @chunks += script.chunks
      return self
    end

    # Appends an opcode (Integer), pushdata (String) or Script and returns self.
    # If Array is passed, this method is recursively called for each element in the array.
    def append(object)
      if object.is_a?(BTC::Script)
        append_script(object)
      elsif object.is_a?(BTC::ScriptNumber)
        append_pushdata(object.data)
      elsif object.is_a?(Integer)
        append_opcode(object)
      elsif object.is_a?(String)
        append_pushdata(object.b)
      elsif object.is_a?(Array)
        object.each do |element|
          self << element
        end
      elsif object.is_a?(ScriptChunk)
        @chunks << object
      else
        raise ArgumentError, "Operand must be an integer, a string a BTC::Script instance or an array of any of those."
      end
      return self
    end
    
    def <<(object)
      append(object)
    end

    # Returns a new instance with concatenation of two scripts.
    def +(other)
      self.dup << other
    end

    # Same arguments as with Array#[].
    def subscript(*args)
      Script.new << chunks[*args]
    end
    alias_method :[], :subscript

    # Removes chunks matching subscript byte-for-byte and returns a new script instance with subscript removed.
    # So if pushdata items are encoded differently, they won't match.
    # Consensus-critical code.
    def find_and_delete(subscript)
      subscript.is_a?(Script) or raise ArgumentError,"Argument must be an instance of BTC::Script"
      # Replacing [a b a]
      # Script: a b b a b a b a c
      # Result: a b b       b a c
      subscriptsize = subscript.chunks.size
      buf = []
      i = 0
      result = Script.new
      chunks.each do |chunk|
        if chunk == subscript.chunks[i]
          buf << chunk
          i+=1
          if i == subscriptsize # matched the whole subscript
            i = 0
            buf.clear
          end
        else
          i = 0
          result << buf
          result << chunk
        end
      end
      result
    end


    # Private API
    # -----------

    # If opcode is nil, then the most compact encoding will be chosen.
    # Returns nil if opcode can't be used for data, or data is nil or too big.
    def self.encode_pushdata(pushdata, opcode: nil)
      raise ArgumentError, "Pushdata is missing" if !pushdata
      if pushdata.bytesize < OP_PUSHDATA1 && opcode == nil
        return BTC::WireFormat.encode_uint8(pushdata.bytesize) + pushdata
      elsif pushdata.bytesize < 0xff && (opcode == nil || opcode == OP_PUSHDATA1)
        return BTC::WireFormat.encode_uint8(OP_PUSHDATA1) +
               BTC::WireFormat.encode_uint8(pushdata.bytesize) +
               pushdata
      elsif pushdata.bytesize < 0xffff && (opcode == nil || opcode == OP_PUSHDATA2)
        return BTC::WireFormat.encode_uint8(OP_PUSHDATA2) +
               BTC::WireFormat.encode_uint16le(pushdata.bytesize) +
               pushdata
      elsif pushdata.bytesize < 0xffffffff && (opcode == nil || opcode == OP_PUSHDATA4)
         return BTC::WireFormat.encode_uint8(OP_PUSHDATA4) +
                BTC::WireFormat.encode_uint32le(pushdata.bytesize) +
                pushdata
      else
        raise ArgumentError, "Invalid opcode or data is too big"
      end
    end

    def detect_multisig_if_needed
      return if @is_multisig != nil
      @is_multisig = detect_multisig
    end

    def detect_multisig
      # multisig script must have at least 4 ops ("OP_1 <pubkey> OP_1 OP_CHECKMULTISIG")
      return false if @chunks.size < 4
      return false if @chunks.last.opcode != OP_CHECKMULTISIG

      m_chunk = @chunks[0]
      n_chunk = @chunks[-2]
      m_opcode = m_chunk.opcode
      n_opcode = n_chunk.opcode

      m = Opcode.small_integer_from_opcode(m_opcode)
      n = Opcode.small_integer_from_opcode(n_opcode)

      # If m or n is not OP_<int>, but a pushdata with little-endian bignum.
      if !m
        return false if !m_chunk.pushdata?
        m = BTC::BigNumber.new(signed_little_endian: m_chunk.pushdata).integer
      end

      if !n
        return false if !n_chunk.pushdata?
        n = BTC::BigNumber.new(signed_little_endian: n_chunk.pushdata).integer
      end

      return false if m < 1 || n < 1 || m > n

      # We must have correct number of pubkeys in the script. 3 extra ops: OP_<M>, OP_<N> and OP_CHECKMULTISIG
      return false if @chunks.size != (3 + n)

      pubkeys = []
      @chunks[1, n].each do |chunk|
        return false if !chunk.pushdata? || chunk.pushdata.bytesize == 0
        pubkeys << chunk.pushdata
      end

      # Now we extracted all pubkeys and verified the numbers.
      @multisig_public_keys = pubkeys
      @multisig_signatures_required = m
      return true
    end

  end # Script
end # BTC
