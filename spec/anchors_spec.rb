# frozen_string_literal: true

RSpec.describe YAMLCamel::Parser do
  def parse(text) = described_class.parse(text)

  describe "anchors and aliases" do
    it "resolves an alias to the scalar its anchor named" do
      expect(parse("a: &x 1\nb: *x\n")).to eq({ "a" => 1, "b" => 1 })
    end

    it "resolves an alias to a collection" do
      expect(parse("a: &x [1, 2]\nb: *x\n")).to eq({ "a" => [1, 2], "b" => [1, 2] })
    end

    it "anchors a block collection written on the lines after its key" do
      expect(parse("a: &x\n  b: 1\nc: *x\n")).to eq({ "a" => { "b" => 1 }, "c" => { "b" => 1 } })
    end

    it "anchors a sequence entry's own value" do
      expect(parse("- &x\n  k: 1\n- *x\n")).to eq([{ "k" => 1 }, { "k" => 1 }])
    end

    it "anchors a node inside a flow collection" do
      expect(parse("[&a 1, *a]")).to eq([1, 1])
      expect(parse("{a: &v 1, b: *v}")).to eq({ "a" => 1, "b" => 1 })
    end

    it "anchors the document's root node" do
      expect(parse("&doc\na: 1\n")).to eq({ "a" => 1 })
    end

    it "shares the value rather than copying it" do
      document = parse("a: &x [1]\nb: *x\n")
      expect(document["b"]).to equal(document["a"])
    end

    it "lets a later anchor of the same name win" do
      expect(parse("- &x 1\n- &x 2\n- *x\n")).to eq([1, 2, 2])
    end

    it "refuses an alias to an anchor that was never defined" do
      expect { parse("a: *nope\n") }.to raise_error(YAMLCamel::UndefinedAliasError)
    end

    it "refuses an alias to an anchor defined only in another document" do
      expect { described_class.parse_stream("---\na: &x 1\n---\nb: *x\n") }
        .to raise_error(YAMLCamel::UndefinedAliasError)
    end

    it "refuses an alias to its own still-unfinished anchor" do
      expect { parse("a: &x [*x]\n") }.to raise_error(YAMLCamel::UndefinedAliasError)
    end

    it "refuses an anchor with no name" do
      expect { parse("a: & 1\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "refuses an alias that also carries an anchor" do
      expect { parse("a: &y *x\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "charges an alias the nodes its anchor holds" do
      limits = YAMLCamel::Limits.default.with(max_nodes: 12)
      expect { described_class.parse("a: &x [1,2,3,4]\nb: *x\nc: *x\n", limits: limits) }
        .to raise_error(YAMLCamel::TooManyNodesError)
    end

    it "charges an alias the levels its anchor holds" do
      limits = YAMLCamel::Limits.default.with(max_depth: 4)
      expect { described_class.parse("a: &x [[[1]]]\nb: [[*x]]\n", limits: limits) }
        .to raise_error(YAMLCamel::DepthExceededError)
    end

    it "bounds how many aliases one stream may dereference" do
      limits = YAMLCamel::Limits.default.with(max_alias_expansions: 3)
      text = "a: &x 1\nb: [#{(["*x"] * 10).join(",")}]\n"
      expect { described_class.parse(text, limits: limits) }
        .to raise_error(YAMLCamel::TooManyAliasesError)
    end
  end
end
