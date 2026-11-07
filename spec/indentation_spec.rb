# frozen_string_literal: true

RSpec.describe YAMLCamel::Parser do
  def parse(text) = described_class.parse(text)

  describe "tabs" do
    it "takes a tab as white space between tokens" do
      expect(parse("key:\tvalue\n")).to eq({ "key" => "value" })
      expect(parse("- \tvalue\n")).to eq(["value"])
      expect(parse("key:\n \tvalue\n")).to eq({ "key" => "value" })
    end

    it "takes a tab before a flow collection that needs no indentation of its own" do
      expect(parse("\t{}\n")).to eq({})
      expect(parse("\t[\n\t]\n")).to eq([])
    end

    it "does not count a tab as indentation for a block collection" do
      expect { parse("a:\n\tb:\n\t\tc: value\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("-\t-\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("?\t-\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("- \t-\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "does not count a tab as indentation inside a flow collection" do
      expect { parse("- [\n\tfoo,\n foo\n ]\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "does not count a tab as indentation for a block scalar" do
      expect { parse("foo: |\n\t\nbar: 1\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "keeps a tab that is content rather than indentation" do
      expect(parse("|\n literal\n \ttext\n")).to eq("literal\n\ttext\n")
    end

    it "takes a tab on a comment line" do
      expect(parse("a: 1\n\t# note\nb: 2\n")).to eq({ "a" => 1, "b" => 2 })
    end
  end

  describe "document markers" do
    it "refuses content glued onto an end marker" do
      expect { parse("---\nkey: value\n... invalid\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "takes a comment after an end marker" do
      expect(parse("---\nkey: value\n... # done\n")).to eq({ "key" => "value" })
    end

    it "refuses a quoted scalar that runs into a document marker" do
      expect { parse("---\n\"\n---\n\"\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("---\n'\n...\n'\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "refuses a quoted scalar continuing at or before its parent's indentation" do
      expect { parse("---\nquoted: \"a\nb\nc\"\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect(parse("---\nquoted: \"a\n b\"\n")).to eq({ "quoted" => "a b" })
    end
  end

  describe "implicit keys" do
    it "refuses a flow sequence pair whose ':' is on another line" do
      expect { parse("---\n[ key\n  : value ]\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("[ \"key\"\n  :value ]\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "takes a flow mapping whose ':' is on another line" do
      expect(parse("{\"foo\"\n: \"bar\"}\n")).to eq({ "foo" => "bar" })
      expect(parse("{ \"foo\"\n  :bar }\n")).to eq({ "foo" => "bar" })
    end

    it "takes a plain flow mapping key that spans lines" do
      expect(parse("{a\n b: 1}\n")).to eq({ "a b" => 1 })
    end
  end

  describe "node properties" do
    it "refuses a block sequence on the line its properties are on" do
      expect { parse("&anchor - sequence entry\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "keeps a mapping's own properties apart from its first key's" do
      expect(parse("!!map\n&a8 !!str key8: value7\n")).to eq({ "key8" => "value7" })
      expect(parse("&a4 !!map\n&a5 !!str key5: value4\n")).to eq({ "key5" => "value4" })
    end

    it "reads properties written across their own lines for one node" do
      expect(parse("&a1\n!!str\nscalar1\n")).to eq("scalar1")
      expect(parse("!!str\n&a2\nscalar2\n")).to eq("scalar2")
    end
  end
end
