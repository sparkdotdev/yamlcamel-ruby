# frozen_string_literal: true

RSpec.describe YAMLCamel::Scalar do
  describe ".resolve" do
    it "reads every spelling of null" do
      ["", "~", "null", "Null", "NULL"].each do |text|
        expect(described_class.resolve(text)).to be_nil
      end
    end

    it "reads every spelling of a boolean" do
      ["true", "True", "TRUE"].each { |text| expect(described_class.resolve(text)).to be(true) }
      ["false", "False", "FALSE"].each { |text| expect(described_class.resolve(text)).to be(false) }
    end

    it "leaves the YAML 1.1 boolean words as strings" do
      %w[yes Yes no No on On off Off y n].each do |text|
        expect(described_class.resolve(text)).to eq(text)
      end
    end

    it "reads decimal, octal and hexadecimal integers" do
      expect(described_class.resolve("0")).to eq(0)
      expect(described_class.resolve("-17")).to eq(-17)
      expect(described_class.resolve("+42")).to eq(42)
      expect(described_class.resolve("0o17")).to eq(15)
      expect(described_class.resolve("0x1F")).to eq(31)
    end

    it "reads an integer wider than a machine word" do
      expect(described_class.resolve("99999999999999999999")).to eq(99_999_999_999_999_999_999)
    end

    it "leaves the YAML 1.1 forms that 1.2 dropped as strings" do
      ["20:03:20", "0b1010", "1_000", "017"].each do |text|
        expected = text == "017" ? 17 : text
        expect(described_class.resolve(text)).to eq(expected)
      end
    end

    it "reads floats that carry a point or an exponent" do
      expect(described_class.resolve("1.5")).to eq(1.5)
      expect(described_class.resolve("-0.5")).to eq(-0.5)
      expect(described_class.resolve(".5")).to eq(0.5)
      expect(described_class.resolve("1.")).to eq(1.0)
      expect(described_class.resolve("1e3")).to eq(1000.0)
      expect(described_class.resolve("-1.2E-3")).to eq(-0.0012)
    end

    it "reads the infinities and the not-a-number forms" do
      expect(described_class.resolve(".inf")).to eq(Float::INFINITY)
      expect(described_class.resolve("+.INF")).to eq(Float::INFINITY)
      expect(described_class.resolve("-.Inf")).to eq(-Float::INFINITY)
      expect(described_class.resolve(".nan")).to be_nan
      expect(described_class.resolve(".NAN")).to be_nan
    end

    it "leaves anything else a string" do
      ["a", "2.4.1", "1-2", "- x", "C#", ".", "e5", "0x", "0o", "+", "-", "1 2"].each do |text|
        expect(described_class.resolve(text)).to eq(text)
      end
    end

    it "keeps an integer an Integer rather than a Float" do
      expect(described_class.resolve("1")).to be_a(Integer)
      expect(described_class.resolve("1.0")).to be_a(Float)
    end
  end

  describe ".numeric?" do
    it "answers for the forms the core schema gives a number to" do
      expect(described_class.numeric?("12")).to be(true)
      expect(described_class.numeric?("0x1f")).to be(true)
      expect(described_class.numeric?("1.5e9")).to be(true)
      expect(described_class.numeric?("x")).to be(false)
    end
  end

  it "resolves a very long run of sign characters without rescanning it repeatedly" do
    text = "-" * 400_000
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(described_class.resolve(text)).to eq(text)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
  end
end

RSpec.describe YAMLCamel::Limits do
  it "reports the bounds it was built with" do
    limits = described_class.new(max_depth: 12, duplicate_keys: :last_wins)
    expect(limits.max_depth).to eq(12)
    expect(limits.duplicate_keys).to eq(:last_wins)
    expect(limits.max_nodes).to eq(described_class.default.max_nodes)
  end

  it "copies with overrides rather than being mutated" do
    limits = described_class.default.with(max_nodes: 5)
    expect(limits.max_nodes).to eq(5)
    expect(described_class.default.max_nodes).not_to eq(5)
  end

  it "refuses a duplicate key policy it does not have" do
    expect { described_class.new(duplicate_keys: :whatever) }.to raise_error(ArgumentError)
  end

  it "clamps the depth ceiling to what the interpreter's stack survives" do
    expect(described_class.default.with(max_depth: 100_000).depth_ceiling)
      .to eq(described_class::MAX_SUPPORTED_DEPTH)
    expect(described_class.default.with(max_depth: 4).depth_ceiling).to eq(4)
  end
end

RSpec.describe YAMLCamel::ParseError do
  it "gives every refusal a kind a caller can match on" do
    expect(YAMLCamel::DepthExceededError.new("x").kind).to eq(:depth_exceeded)
    expect(YAMLCamel::SyntaxError.new("x").kind).to eq(:syntax)
  end

  it "tells a bound being crossed apart from malformed input" do
    expect(YAMLCamel::TooManyNodesError.new("x")).to be_limit
    expect(YAMLCamel::SyntaxError.new("x")).not_to be_limit
    expect(YAMLCamel::DuplicateKeyError.new("x")).not_to be_limit
  end

  it "names the line when it knows it" do
    expect(YAMLCamel::SyntaxError.new("bad", line: 4).message).to include("line 4")
    expect(YAMLCamel::SyntaxError.new("bad").message).not_to include("line")
  end

  it "is rescuable as one family" do
    expect(YAMLCamel::DepthExceededError.new("x")).to be_a(YAMLCamel::ParseError)
    expect(YAMLCamel::DepthExceededError.new("x")).to be_a(YAMLCamel::Error)
    expect(YAMLCamel::OutputTooLargeError.new("x")).to be_a(YAMLCamel::EmitError)
  end
end
