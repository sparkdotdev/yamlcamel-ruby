# frozen_string_literal: true

RSpec.describe YAMLCamel::Parser do
  def parse(text) = described_class.parse(text)

  describe "block mappings" do
    it "reads an entry per line" do
      expect(parse("a: 1\nb: two\n")).to eq({ "a" => 1, "b" => "two" })
    end

    it "nests a mapping under a key" do
      expect(parse("a:\n  b: 1\n  c: 2\n")).to eq({ "a" => { "b" => 1, "c" => 2 } })
    end

    it "reads an omitted value as null" do
      expect(parse("a:\nb: 1\n")).to eq({ "a" => nil, "b" => 1 })
    end

    it "keeps the order the keys were written in" do
      expect(parse("z: 1\na: 2\nm: 3\n").keys).to eq(%w[z a m])
    end

    it "takes a sequence at its key's own indentation" do
      expect(parse("a:\n- 1\n- 2\n")).to eq({ "a" => [1, 2] })
    end

    it "takes a sequence indented past its key" do
      expect(parse("a:\n  - 1\n  - 2\n")).to eq({ "a" => [1, 2] })
    end

    it "refuses a line indented past the mapping it belongs to" do
      expect { parse("a: 1\n  b: 2\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "folds an over-indented continuation into the scalar rather than dropping it" do
      expect(parse("a: 1\n   oops\nb: 2\n")).to eq({ "a" => "1 oops", "b" => 2 })
    end

    it "reads a key that is not a string as the value the core schema gives it" do
      expect(parse("1: one\ntrue: yes\n")).to eq({ 1 => "one", true => "yes" })
    end
  end

  describe "explicit keys" do
    it "reads a '?' key and its ':' value" do
      expect(parse("? key\n: value\n")).to eq({ "key" => "value" })
    end

    it "reads an explicit key with no value as null" do
      expect(parse("? key\n")).to eq({ "key" => nil })
    end

    it "reads an omitted key as null" do
      expect(parse(": value\n")).to eq({ nil => "value" })
      expect(parse("?\n: value\n")).to eq({ nil => "value" })
    end

    it "takes a collection on either side" do
      expect(parse("? - a\n  - b\n: - c\n")).to eq({ %w[a b] => ["c"] })
    end

    it "keeps a collection key rather than flattening it" do
      expect(parse("[a, b]: value\n")).to eq({ %w[a b] => "value" })
      expect(parse("{a: 1}: value\n")).to eq({ { "a" => 1 } => "value" })
    end
  end

  describe "block sequences" do
    it "reads an entry per dash" do
      expect(parse("- 1\n- 2\n- 3\n")).to eq([1, 2, 3])
    end

    it "reads a mapping written compactly after the dash" do
      expect(parse("- a: 1\n  b: 2\n- c: 3\n")).to eq([{ "a" => 1, "b" => 2 }, { "c" => 3 }])
    end

    it "reads a sequence written compactly after the dash" do
      expect(parse("- - 1\n  - 2\n")).to eq([[1, 2]])
    end

    it "reads an empty entry as null" do
      expect(parse("- 1\n-\n- 3\n")).to eq([1, nil, 3])
    end

    it "reads a nested sequence indented under its dash" do
      expect(parse("-\n  - 1\n  - 2\n")).to eq([[1, 2]])
    end

    it "folds a dash indented past its entry into that entry's scalar" do
      # Past the entry's own column a '-' is text rather than an indicator, so these are one scalar.
      expect(parse("- 1\n   - 2\n  - 3\n")).to eq(["1 - 2 - 3"])
    end

    it "refuses a mapping key indented past the mapping it belongs to" do
      expect { parse("a:\n  b: 1\n   c: 2\n") }.to raise_error(YAMLCamel::SyntaxError)
    end
  end

  describe "flow collections" do
    it "reads a flow sequence" do
      expect(parse("[1, 2, 3]")).to eq([1, 2, 3])
      expect(parse("[]")).to eq([])
    end

    it "reads a flow mapping" do
      expect(parse("{a: 1, b: 2}")).to eq({ "a" => 1, "b" => 2 })
      expect(parse("{}")).to eq({})
    end

    it "nests one inside the other" do
      expect(parse("a: [1, {b: 2}]\n")).to eq({ "a" => [1, { "b" => 2 }] })
      expect(parse("{a: [1, 2], b: {c: 3}}")).to eq({ "a" => [1, 2], "b" => { "c" => 3 } })
    end

    it "takes a trailing comma" do
      expect(parse("[1, 2, ]")).to eq([1, 2])
      expect(parse("{a: 1, }")).to eq({ "a" => 1 })
    end

    it "spans lines" do
      expect(parse("a: [\n  1,\n  2,\n ]\n")).to eq({ "a" => [1, 2] })
    end

    it "reads a single pair inside a flow sequence as a one-entry mapping" do
      expect(parse("[a: 1, b]")).to eq([{ "a" => 1 }, "b"])
      expect(parse("[? a : 1]")).to eq([{ "a" => 1 }])
    end

    it "reads a missing flow value as null" do
      expect(parse("{a: , b}")).to eq({ "a" => nil, "b" => nil })
      expect(parse("[a: ]")).to eq([{ "a" => nil }])
    end

    it "reads a quoted key that a colon follows with no space" do
      expect(parse('{"a":1}')).to eq({ "a" => 1 })
      expect(parse("[a]: 1\n")).to eq({ ["a"] => 1 })
    end

    it "keeps a comma inside a plain scalar outside flow brackets" do
      expect(parse("a: one, two\n")).to eq({ "a" => "one, two" })
    end

    it "reports a flow collection that never closes" do
      ["[1, 2", "{a: 1", "a: [1,\n", "[a: [b]"].each do |text|
        expect { parse(text) }.to raise_error(YAMLCamel::SyntaxError)
      end
    end

    it "refuses a flow collection that dedents out of its parent" do
      expect { parse("a: [1,\n2]\n") }.to raise_error(YAMLCamel::SyntaxError)
    end
  end

  describe "duplicate keys" do
    it "refuses a repeated key by default" do
      expect { parse("a: 1\na: 2\n") }.to raise_error(YAMLCamel::DuplicateKeyError)
      expect { parse("{a: 1, a: 2}") }.to raise_error(YAMLCamel::DuplicateKeyError)
    end

    it "keeps the first or the last occurrence when asked to" do
      first = YAMLCamel::Limits.default.with(duplicate_keys: :first_wins)
      last = YAMLCamel::Limits.default.with(duplicate_keys: :last_wins)
      expect(described_class.parse("a: 1\na: 2\n", limits: first)).to eq({ "a" => 1 })
      expect(described_class.parse("a: 1\na: 2\n", limits: last)).to eq({ "a" => 2 })
    end

    it "keeps the position of the first occurrence when the last one wins" do
      last = YAMLCamel::Limits.default.with(duplicate_keys: :last_wins)
      expect(described_class.parse("a: 1\nb: 2\na: 3\n", limits: last).keys).to eq(%w[a b])
    end
  end

  describe "comments" do
    it "drops a comment line between entries" do
      expect(parse("a: 1\n# note\nb: 2\n")).to eq({ "a" => 1, "b" => 2 })
    end

    it "drops a comment after a value" do
      expect(parse("a: 1 # note\n")).to eq({ "a" => 1 })
    end

    it "drops a comment inside a flow collection" do
      expect(parse("[1, # note\n 2]")).to eq([1, 2])
    end
  end
end
