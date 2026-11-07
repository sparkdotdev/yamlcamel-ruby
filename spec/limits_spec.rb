# frozen_string_literal: true

# Every bound the parser applies, with a case that proves it refuses cleanly.
#
# A refusal here is the correct outcome. What these guard against is the parser crashing, hanging or
# exhausting memory, and each one names the error class a caller can rescue.
RSpec.describe "resource guards" do
  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  describe "nesting" do
    it "refuses nested flow brackets rather than overflowing the stack" do
      [1_000, 2_000, 4_000, 32_000].each do |depth|
        text = "k: #{"[" * depth}#{"]" * depth}"
        expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::DepthExceededError), depth.to_s
      end
    end

    it "does not let a caller raise the depth bound past what the stack survives" do
      limits = YAMLCamel::Limits.default.with(max_depth: 100_000)
      text = ("[" * 4_000) + ("]" * 4_000)
      expect { YAMLCamel.load(text, limits: limits) }.to raise_error(YAMLCamel::DepthExceededError)
    end

    it "bounds a document alternating sequences with mappings" do
      text = (0...500).map { |level| "#{" " * (level * 4)}- a:\n" }.join
      expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::DepthExceededError)
    end

    it "bounds nested block sequences" do
      text = (0...4_000).map { |level| "#{" " * (level * 2)}-\n" }.join
      expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::DepthExceededError)
    end

    it "bounds nested flow mappings" do
      text = ("{a: " * 4_000) + "1" + ("}" * 4_000)
      expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::DepthExceededError)
    end

    it "still parses a document just inside the depth bound" do
      depth = YAMLCamel::Limits::MAX_SUPPORTED_DEPTH - 2
      expect(YAMLCamel.load(("[" * depth) + ("]" * depth))).to be_an(Array)
    end

    it "reports a refusal as a limit rather than as malformed input" do
      YAMLCamel.load("[" * 4_000)
    rescue YAMLCamel::ParseError => e
      expect(e).to be_limit
      expect(e.kind).to eq(:depth_exceeded)
    end
  end

  describe "aliases" do
    it "refuses recursive aliases inflating a small document" do
      text = <<~YAML
        a: &a ["lol","lol","lol","lol","lol","lol","lol","lol","lol"]
        b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
        c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
        d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]
        e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]
        f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e]
        g: &g [*f,*f,*f,*f,*f,*f,*f,*f,*f]
        h: &h [*g,*g,*g,*g,*g,*g,*g,*g,*g]
        i: &i [*h,*h,*h,*h,*h,*h,*h,*h,*h]
      YAML
      expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::TooManyNodesError)
    end

    it "bounds how many dereferences one stream may make" do
      limits = YAMLCamel::Limits.default.with(max_alias_expansions: 50)
      text = "a: &a x\nb: [#{(["*a"] * 200).join(",")}]"
      expect { YAMLCamel.load(text, limits: limits) }.to raise_error(YAMLCamel::TooManyAliasesError)
    end

    it "refuses an alias to an anchor that was never defined" do
      expect { YAMLCamel.load("a: *nope") }.to raise_error(YAMLCamel::UndefinedAliasError)
    end

    it "does not carry an anchor across a document boundary" do
      expect { YAMLCamel.load_stream("---\na: &x 1\n---\nb: *x\n") }
        .to raise_error(YAMLCamel::UndefinedAliasError)
    end

    it "does not restart the node budget at a document boundary" do
      # Anchors do not cross a '---', so every document rebuilds the bomb and pays for it again.
      bomb = <<~YAML
        a: &a [x,x,x,x,x,x,x,x,x]
        b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
        c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
        d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]
        e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]
        f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e]
      YAML
      stream = "---\n#{bomb}" * 1024
      expect(stream.bytesize).to be < 300_000

      took = elapsed do
        expect { YAMLCamel.load_stream(stream) }.to raise_error(YAMLCamel::TooManyNodesError)
      end
      expect(took).to be < 20
    end
  end

  describe "size" do
    it "refuses input larger than the byte bound before scanning it" do
      limits = YAMLCamel::Limits.default.with(max_input_bytes: 1_000)
      expect { YAMLCamel.load("a: #{"x" * 2_000}", limits: limits) }
        .to raise_error(YAMLCamel::InputTooLargeError)
    end

    it "refuses an oversized stream without reading all of it" do
      require "stringio"
      limits = YAMLCamel::Limits.default.with(max_input_bytes: 1_000)
      io = StringIO.new("a: #{"x" * 100_000}")
      expect { YAMLCamel.load(io, limits: limits) }.to raise_error(YAMLCamel::InputTooLargeError)
      expect(io.pos).to be <= 1_001
    end

    it "refuses a single enormous scalar" do
      limits = YAMLCamel::Limits.default.with(max_scalar_length: 1_000)
      expect { YAMLCamel.load("a: #{"x" * 50_000}", limits: limits) }
        .to raise_error(YAMLCamel::ScalarTooLongError)
    end

    it "refuses an enormous block scalar while it is being read" do
      limits = YAMLCamel::Limits.default.with(max_scalar_length: 2_000)
      text = "a: |\n#{"  #{"a" * 32}\n" * 5_000}"
      expect { YAMLCamel.load(text, limits: limits) }.to raise_error(YAMLCamel::ScalarTooLongError)
    end

    it "refuses an enormous quoted scalar while it is being read" do
      limits = YAMLCamel::Limits.default.with(max_scalar_length: 2_000)
      expect { YAMLCamel.load(%(a: "#{"x" * 50_000}"), limits: limits) }
        .to raise_error(YAMLCamel::ScalarTooLongError)
    end

    it "refuses a document with more nodes than the bound" do
      limits = YAMLCamel::Limits.default.with(max_nodes: 5_000)
      text = (0...50_000).map { |index| "k#{index}: #{index}\n" }.join
      expect { YAMLCamel.load(text, limits: limits) }.to raise_error(YAMLCamel::TooManyNodesError)
    end

    it "refuses a stream with more documents than the bound" do
      limits = YAMLCamel::Limits.default.with(max_documents: 10)
      expect { YAMLCamel.load_stream("---\na: 1\n" * 100, limits: limits) }
        .to raise_error(YAMLCamel::TooManyDocumentsError)
    end

    it "refuses a numeric literal with more digits than the bound" do
      # Turning digits into an Integer costs more than linear time in their count, which the scalar
      # bound alone does not cover.
      took = elapsed do
        expect { YAMLCamel.load("a: #{"9" * 200_000}") }.to raise_error(YAMLCamel::NumberTooLongError)
      end
      expect(took).to be < 5
    end

    it "leaves a long non-numeric scalar alone" do
      expect(YAMLCamel.load("a: #{"x" * 200_000}")["a"].length).to eq(200_000)
    end
  end

  describe "tags" do
    it "refuses a resolved tag longer than the bound" do
      limits = YAMLCamel::Limits.default.with(max_tag_length: 16)
      expect { YAMLCamel.load("--- !<tag:#{"x" * 100}> 1\n", limits: limits) }
        .to raise_error(YAMLCamel::TagTooLongError)
    end

    it "checks a handle's prefix against every use rather than the directive once" do
      # A %TAG prefix is declared once but can be joined onto a short suffix any number of times.
      # Checking after the join would pay the cost the bound exists to avoid before ever refusing.
      n = 4_000_000
      text = "%TAG !e! #{"p" * (n / 2)}\n---\n#{"- !e!x\n" * (n / 16)}"
      took = elapsed do
        expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::TagTooLongError)
      end
      expect(took).to be < 5
    end

    it "leaves an ordinary short tag alone" do
      expect(YAMLCamel.load("%TAG !e! tag:example.com,2000:app/\n---\n!e!t 1\n")).to eq(1)
      expect(YAMLCamel.load("--- !!str hi\n")).to eq("hi")
      expect(YAMLCamel.load("--- !<tag:yaml.org,2002:str> hi\n")).to eq("hi")
    end

    it "checks the primary handle's own redefined prefix the same way, not after joining it" do
      # %TAG ! redefines the primary handle a bare '!tag' shorthand uses, the same shape of cost
      # a named handle's prefix has, and it needs the same check on the raw pieces before them.
      limits = YAMLCamel::Limits.default.with(max_tag_length: 16)
      expect { YAMLCamel.load("%TAG ! #{"p" * 100}\n---\n!x 1\n", limits: limits) }
        .to raise_error(YAMLCamel::TagTooLongError)
    end

    it "does not run the digit guard against a value an explicit !!str tag never converts" do
      digits = "1" * 5_000
      expect(YAMLCamel.load("!!str #{digits}")).to eq(digits)
      expect(YAMLCamel.load(%(!!str "#{digits}"))).to eq(digits)
    end

    it "still runs the digit guard for a tag that does convert the text" do
      expect { YAMLCamel.load("!!int #{"1" * 5_000}") }.to raise_error(YAMLCamel::NumberTooLongError)
      expect { YAMLCamel.load("!!float #{"1" * 5_000}.0") }.to raise_error(YAMLCamel::NumberTooLongError)
    end

    it "stays fast on the primary handle at the same scale the named-handle attack used" do
      # The same shape of attack the named-handle fix above guards against, redefining the
      # primary '!' handle instead: a long prefix used thousands of times has to refuse on the
      # first use rather than pay to build the joined string once per use.
      n = 4_000_000
      text = "%TAG ! #{"p" * (n / 2)}\n---\n#{"- !x\n" * (n / 16)}"
      took = elapsed do
        expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::TagTooLongError)
      end
      expect(took).to be < 5
    end
  end

  describe "duplicate keys" do
    it "refuses a repeated key by default" do
      expect { YAMLCamel.load("a: 1\na: 2\n") }.to raise_error(YAMLCamel::DuplicateKeyError)
    end

    it "refuses a repeated key inside a flow mapping" do
      expect { YAMLCamel.load("{a: 1, a: 2}") }.to raise_error(YAMLCamel::DuplicateKeyError)
    end
  end

  describe "malformed input" do
    it "refuses bytes that are not valid UTF-8 with a parse error" do
      text = "a: \xFF\xFE\x80\n".dup.force_encoding(Encoding::ASCII_8BIT)
      expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "reports a truncated stream rather than returning a partial value" do
      ["a: [1, 2", "a: {b: 1", 'a: "unterminated', "a: 'unterminated", "%YAML 1.2"].each do |text|
        expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::ParseError), text
      end
    end

    it "reports content after a document rather than dropping it" do
      ["a: 1\n  b: 2\n", "[1, 2]\nfoo: bar\n", "{a: 1}\n- item\n"].each do |text|
        expect { YAMLCamel.load(text) }.to raise_error(YAMLCamel::ParseError), text
      end
    end
  end

  describe "work the bounds are there to cap" do
    it "reads a hundred thousand short flow lines quickly" do
      text = "k: [\n#{(0...100_000).map { |index| " a#{index},\n" }.join} ]\n"
      value = nil
      took = elapsed { value = YAMLCamel.load(text, limits: YAMLCamel::Limits.permissive) }
      expect(value["k"].length).to eq(100_000)
      expect(took).to be < 30
    end

    it "reads a hundred thousand joined quoted lines quickly" do
      text = "k: \"\n#{(0...100_000).map { |index| " a#{index}\n" }.join} \"\n"
      took = elapsed { YAMLCamel.load(text, limits: YAMLCamel::Limits.permissive) }
      expect(took).to be < 30
    end

    it "does not recount a quoted scalar for every escape it holds" do
      [40_000, 160_000, 640_000].each do |count|
        text = %(a: "#{"\\n" * count}"\n)
        value = nil
        took = elapsed { value = YAMLCamel.load(text) }
        expect(value["a"]).to eq("\n" * count)
        expect(took).to be < 10
      end
    end

    it "stays linear reading a single-quoted scalar with many doubled quotes" do
      # Appending the escaped quote by its codepoint rather than as a one-character String does
      # not amortize the way every other escape's append does, so a run of them cost the
      # scalar's own length again on every one, the same shape of cost the bound above guards.
      [100_000, 400_000, 1_600_000].each do |count|
        text = %(a: '#{"x''" * count}'\n)
        value = nil
        took = elapsed { value = YAMLCamel.load(text, limits: YAMLCamel::Limits.permissive) }
        expect(value["a"]).to eq("x'" * count)
        expect(took).to be < 10
      end
    end

    it "stays linear with escapes mixed through a large quoted scalar" do
      text = %(a: "#{(("x" * 100) + "\\n") * 20_000}"\n)
      took = elapsed { YAMLCamel.load(text) }
      expect(took).to be < 10
    end

    it "does not measure an anchored subtree by walking it" do
      # An anchor at every level used to cost the size of its own subtree, which is the size of the
      # document once per level.
      depth = 200
      text = (0...depth).map { |level| "#{" " * level}- &a#{level}\n" }.join +
             ("#{" " * depth}#{(0...2_000).map { |index| "- x#{index}\n#{" " * depth}" }.join}".rstrip + "\n")
      took = elapsed { YAMLCamel.load(text, limits: YAMLCamel::Limits.permissive) }
      expect(took).to be < 20
    end
  end

  describe "emitting against parsing" do
    it "can write more than the input bound allows for a document that parsed" do
      # Aliases hold the node count under its budget while multiplying what the emitter writes.
      text = +"a: &a [xx,xx,xx,xx,xx,xx,xx,xx,xx,xx]\n"
      "abcd".chars.zip("bcde".chars).each do |previous, name|
        text << "#{name}: &#{name} [#{(["*#{previous}"] * 10).join(",")}]\n"
      end
      expect(text.bytesize).to be < 300

      # Read on a bound a tenth of the default, so the same asymmetry costs a tenth of the work.
      reading = YAMLCamel::Limits.default.with(max_input_bytes: 1 << 20)
      document = YAMLCamel.load(text, limits: reading)
      emitted = YAMLCamel.dump(document, limits: YAMLCamel::EmitLimits.permissive)
      expect(emitted.bytesize).to be > reading.max_input_bytes

      expect { YAMLCamel.load(emitted, limits: reading) }.to raise_error(YAMLCamel::InputTooLargeError)
      expect(YAMLCamel.load(emitted, limits: YAMLCamel::Limits.permissive)).to eq(document)
    end
  end
end
