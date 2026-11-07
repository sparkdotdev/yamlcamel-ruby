# frozen_string_literal: true

RSpec.describe YAMLCamel::Emitter do
  def dump(value, **options) = YAMLCamel.dump(value, **options)

  describe "collections" do
    it "writes a mapping one entry per line" do
      expect(dump({ "a" => 1, "b" => "two" })).to eq("a: 1\nb: two\n")
    end

    it "writes a sequence at its key's own indentation" do
      expect(dump({ "a" => [1, 2] })).to eq("a:\n- 1\n- 2\n")
    end

    it "writes a nested mapping indented two further" do
      expect(dump({ "a" => { "b" => 1 } })).to eq("a:\n  b: 1\n")
    end

    it "puts a sequence item's first mapping key on the dash line" do
      expect(dump([{ "a" => 1, "b" => 2 }])).to eq("- a: 1\n  b: 2\n")
    end

    it "writes an empty collection in flow style" do
      expect(dump({})).to eq("{}\n")
      expect(dump([])).to eq("[]\n")
      expect(dump({ "a" => {}, "b" => [] })).to eq("a: {}\nb: []\n")
      expect(dump([[], {}])).to eq("- []\n- {}\n")
    end

    it "writes a sequence nested in a sequence under its own dash" do
      expect(dump([[1]])).to eq("-\n  - 1\n")
    end

    it "keeps insertion order by default and sorts when asked" do
      value = { "b" => 1, "a" => 2 }
      expect(dump(value)).to eq("b: 1\na: 2\n")
      expect(dump(value, sort_keys: true)).to eq("a: 2\nb: 1\n")
    end

    it "sorts keys of mixed types without raising" do
      expect(dump({ 2 => "b", "a" => 1, nil => "c" }, sort_keys: true)).to be_a(String)
    end
  end

  describe "scalars" do
    it "writes the core schema types" do
      expect(dump(nil)).to eq("null\n")
      expect(dump(true)).to eq("true\n")
      expect(dump(17)).to eq("17\n")
      expect(dump(1.5)).to eq("1.5\n")
      expect(dump("text")).to eq("text\n")
    end

    it "keeps a float readable as a float" do
      expect(dump(2.0)).to eq("2.0\n")
      expect(dump(-0.0)).to eq("-0.0\n")
      expect(dump(Float::INFINITY)).to eq(".inf\n")
      expect(dump(-Float::INFINITY)).to eq("-.inf\n")
      expect(dump(Float::NAN)).to eq(".nan\n")
    end

    it "writes an integer wider than a machine word" do
      expect(dump(2**80)).to eq("#{2**80}\n")
    end

    it "quotes a string that would read back as something else" do
      expect(dump("17")).to eq('"17"' + "\n")
      expect(dump("true")).to eq('"true"' + "\n")
      expect(dump("~")).to eq('"~"' + "\n")
      expect(dump("")).to eq('""' + "\n")
      expect(dump(".inf")).to eq('".inf"' + "\n")
    end

    it "leaves a YAML 1.1 boolean word plain, since the core schema reads it as a string" do
      expect(dump("yes")).to eq("yes\n")
    end

    it "quotes a string an indicator character would break" do
      ["a: b", "a #b", "[a]", "{a}", "a,b", "&a", "*a", "!a", "|a", ">a", "%a", "@a", "`a",
       "-", "- a", "? a", "a:", " a", "a ", "--- x", "... x"].each do |text|
        expect(dump(text)).to start_with('"'), "#{text.inspect} was written plain"
      end
    end

    it "escapes the characters a double-quoted scalar cannot hold" do
      expect(dump("a\nb")).to eq(%("a\\nb"\n))
      expect(dump("a\tb")).to eq(%("a\\tb"\n))
      expect(dump("a\u0000b")).to eq(%("a\\x00b"\n))
      expect(dump("a\u0085b")).to eq(%("a\\Nb"\n))
      expect(dump("\uFEFF")).to eq(%("\\uFEFF"\n))
    end

    it "leaves a non-breaking space plain, since it is ordinary scalar content" do
      expect(dump("a\u00A0b")).to eq("a\u00A0b\n")
      expect(YAMLCamel.load(dump("a\u00A0b"))).to eq("a\u00A0b")
    end

    it "writes a symbol as the string of its name" do
      expect(dump(:name)).to eq("name\n")
    end

    it "refuses a type the core schema has no representation for" do
      expect { dump(Object.new) }.to raise_error(YAMLCamel::UnsupportedTypeError)
      expect { dump(Time.now) }.to raise_error(YAMLCamel::UnsupportedTypeError)
    end

    it "quotes a scalar that starts with a colon so a flow key reads back" do
      # A collection key is written in flow style, and a flow mapping reads a leading ':' as its
      # value indicator before it looks for a key, so ':x' written plain came back out unreadable.
      expect(dump({ ":x" => 1 })).to eq("\":x\": 1\n")
      expect(dump([":x"])).to eq("- \":x\"\n")
      [{ { ":x" => 1 } => "v" }, { [":x"] => "v" }, { { ":" => ":x" } => ":\\" }].each do |value|
        text = dump(value)
        expect { YAMLCamel.load(text) }.not_to raise_error, text.inspect
        expect(dump(YAMLCamel.load(text))).to eq(text)
      end
    end

    it "refuses a string whose bytes do not read as UTF-8" do
      # A string the parser produced is always valid, since the reader scrubs what it reads. One the
      # caller built is not, and used to reach a regular expression as raw bytes and raise
      # ArgumentError from inside the core schema rather than an error of this library's own.
      [(+"\xFF").force_encoding(Encoding::UTF_8),
       (+"a\xC3").force_encoding(Encoding::UTF_8),
       (+"\xC0\x80").force_encoding(Encoding::UTF_8),
       (+"\xED\xA0\x80").force_encoding(Encoding::UTF_8)].each do |text|
        expect { dump(text) }.to raise_error(YAMLCamel::UnsupportedTypeError), text.inspect
        expect { dump([text]) }.to raise_error(YAMLCamel::UnsupportedTypeError), text.inspect
        expect { dump({ text => 1 }) }.to raise_error(YAMLCamel::UnsupportedTypeError), text.inspect
        expect { dump({ "k" => text }) }.to raise_error(YAMLCamel::UnsupportedTypeError), text.inspect
      end
    end

    it "writes a string in another encoding as its UTF-8 text" do
      expect(dump("abc".encode(Encoding::UTF_16LE))).to eq("abc\n")
      expect(dump((+"caf\xE9").force_encoding(Encoding::ISO_8859_1))).to eq("café\n")
      expect(dump("café".b)).to eq("café\n")
      expect(dump("abc".b)).to eq("abc\n")
      %w[abc café].each do |text|
        expect(dump(text.encode(Encoding::UTF_16BE)).encoding).to eq(Encoding::UTF_8)
      end
    end
  end

  describe "collection keys" do
    it "writes a key that is itself a collection the explicit way" do
      expect(dump({ %w[a b] => "value" })).to eq("? [a, b]\n: value\n")
      expect(dump({ { "a" => 1 } => 2 })).to eq("? {a: 1}\n: 2\n")
    end

    it "writes a collection value under an explicit key" do
      expect(dump({ [1] => [2] })).to eq("? [1]\n:\n- 2\n")
    end
  end

  describe "mapping key collisions" do
    def last_wins_limits = YAMLCamel::Limits.default.with(duplicate_keys: :last_wins)

    it "refuses a Symbol key and a String key that share a name" do
      expect { dump({ foo: 1, "foo" => 2 }) }.to raise_error(YAMLCamel::AmbiguousKeyError)
    end

    it "reports the ambiguous key kind" do
      dump({ foo: 1, "foo" => 2 })
    rescue YAMLCamel::AmbiguousKeyError => e
      expect(e.kind).to eq(:ambiguous_key)
    end

    it "refuses the pair even when the shared name is a reserved word" do
      # :true and "true" would both end up quoted for the same reason, so quoting alone cannot
      # tell them apart either.
      expect { dump({ true: 1, "true" => 2 }) }.to raise_error(YAMLCamel::AmbiguousKeyError)
    end

    it "refuses the pair with sort_keys on, since the collision does not depend on order" do
      expect { dump({ foo: 1, "foo" => 2 }, sort_keys: true) }
        .to raise_error(YAMLCamel::AmbiguousKeyError)
    end

    it "only compares keys within the same mapping" do
      value = { "a" => { "foo" => 1 }, "b" => { "foo" => 2 } }
      expect(dump(value)).to eq("a:\n  foo: 1\nb:\n  foo: 2\n")
    end

    it "still writes a Symbol key alongside an unrelated String key" do
      expect(dump({ a: 1, "b" => 2 })).to eq("a: 1\nb: 2\n")
    end

    it "still round-trips the true/\"true\" pair under :reject and :last_wins" do
      text = dump({ true => 1, "true" => 2 })
      expect(text).to eq(%(true: 1\n"true": 2\n))
      expect(YAMLCamel.load(text)).to eq({ true => 1, "true" => 2 })
      expect(YAMLCamel.load(text, limits: last_wins_limits)).to eq({ true => 1, "true" => 2 })
    end

    it "still round-trips the 1/\"1\" pair under :reject and :last_wins" do
      text = dump({ 1 => "a", "1" => "b" })
      expect(text).to eq(%(1: a\n"1": b\n))
      expect(YAMLCamel.load(text)).to eq({ 1 => "a", "1" => "b" })
      expect(YAMLCamel.load(text, limits: last_wins_limits)).to eq({ 1 => "a", "1" => "b" })
    end
  end

  describe "limits" do
    it "refuses output larger than the byte bound" do
      limits = YAMLCamel::EmitLimits.default.with(max_output_bytes: 20)
      expect { dump({ "a" => "x" * 100 }, limits: limits) }
        .to raise_error(YAMLCamel::OutputTooLargeError)
    end

    it "refuses a value with more nodes than the bound" do
      limits = YAMLCamel::EmitLimits.default.with(max_nodes: 5)
      expect { dump((1..100).to_a, limits: limits) }
        .to raise_error(YAMLCamel::EmitTooManyNodesError)
    end

    it "refuses a value that nests deeper than the bound" do
      limits = YAMLCamel::EmitLimits.default.with(max_depth: 3)
      expect { dump([[[[1]]]], limits: limits) }
        .to raise_error(YAMLCamel::EmitDepthExceededError)
    end

    it "refuses a value that holds itself rather than recursing forever" do
      loop_value = []
      loop_value << loop_value
      expect { dump(loop_value) }.to raise_error(YAMLCamel::EmitDepthExceededError)
    end

    it "carries the byte budget across dump_stream's documents" do
      limits = YAMLCamel::EmitLimits.default.with(max_output_bytes: 100)
      documents = Array.new(5) { { "k" => "x" * 50 } }
      expect(YAMLCamel::Emitter.emit(documents.first, limits: limits).bytesize).to be < 100
      expect { YAMLCamel.dump_stream(*documents, limits: limits) }
        .to raise_error(YAMLCamel::OutputTooLargeError)
    end

    it "carries the node budget across dump_stream's documents" do
      limits = YAMLCamel::EmitLimits.default.with(max_nodes: 20)
      documents = Array.new(5) { (1..10).to_a }
      expect { YAMLCamel.dump_stream(*documents, limits: limits) }
        .to raise_error(YAMLCamel::EmitTooManyNodesError)
    end

    it "does not double count a collection-valued key's scalar bytes" do
      limits = YAMLCamel::EmitLimits.default.with(max_output_bytes: 13)
      expect(dump({ %w[a b] => "x" }, limits: limits)).to eq("? [a, b]\n: x\n")
    end
  end

  describe "the module level API" do
    it "writes into an IO when given one" do
      require "stringio"
      io = StringIO.new
      expect(YAMLCamel.dump({ "a" => 1 }, io)).to be(io)
      expect(io.string).to eq("a: 1\n")
    end

    it "writes several documents as one stream" do
      expect(YAMLCamel.dump_stream({ "a" => 1 }, [2])).to eq("---\na: 1\n---\n- 2\n")
      expect(YAMLCamel.load_stream(YAMLCamel.dump_stream(1, 2))).to eq([1, 2])
    end

    it "reads the first document and the whole stream" do
      expect(YAMLCamel.load("--- 1\n--- 2\n")).to eq(1)
      expect(YAMLCamel.load_stream("--- 1\n--- 2\n")).to eq([1, 2])
      expect { YAMLCamel.load_one("--- 1\n--- 2\n") }.to raise_error(YAMLCamel::DocumentCountError)
    end

    it "reads an empty stream as nil" do
      expect(YAMLCamel.load("")).to be_nil
      expect(YAMLCamel.safe_load("")).to be_nil
    end
  end
end
