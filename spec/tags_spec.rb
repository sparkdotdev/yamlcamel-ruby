# frozen_string_literal: true

RSpec.describe YAMLCamel::Tag do
  def parse(text) = YAMLCamel::Parser.parse(text)

  describe "core schema tags" do
    it "forces a scalar to the type the tag names" do
      expect(parse("a: !!str 1\n")).to eq({ "a" => "1" })
      expect(parse("a: !!int '17'\n")).to eq({ "a" => 17 })
      expect(parse("a: !!float 3\n")).to eq({ "a" => 3.0 })
      expect(parse("a: !!bool true\n")).to eq({ "a" => true })
      expect(parse("a: !!null ~\n")).to eq({ "a" => nil })
    end

    it "refuses a tag the text cannot carry" do
      expect { parse("a: !!bool 7\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("a: !!int x\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("a: !!null 1\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("a: !!float x\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "tags a collection with its own kind" do
      expect(parse("a: !!seq [1, 2]\n")).to eq({ "a" => [1, 2] })
      expect(parse("a: !!map {b: 1}\n")).to eq({ "a" => { "b" => 1 } })
    end

    it "refuses a collection tag on the other kind of collection" do
      expect { parse("a: !!seq {b: 1}\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("a: !!map [1]\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("a: !!str [1]\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("a: !!seq x\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "reads the non-specific tag on a scalar as a string" do
      expect(parse("a: ! 42\n")).to eq({ "a" => "42" })
      expect(parse("a: !<!> 42\n")).to eq({ "a" => "42" })
    end

    it "leaves a tag outside the core schema as an annotation" do
      expect(parse("a: !custom 42\n")).to eq({ "a" => 42 })
      expect(parse("a: !<tag:example.com,2020:thing> 42\n")).to eq({ "a" => 42 })
      expect(parse("a: !!binary aGk=\n")).to eq({ "a" => "aGk=" })
    end

    it "carries a tag and an anchor together in either order" do
      expect(parse("a: !!str &x 1\nb: *x\n")).to eq({ "a" => "1", "b" => "1" })
      expect(parse("a: &x !!str 1\nb: *x\n")).to eq({ "a" => "1", "b" => "1" })
    end

    it "tags a block scalar" do
      expect(parse("a: !!str |\n  text\n")).to eq({ "a" => "text\n" })
    end

    it "tags a node written on the line after its key" do
      expect(parse("a: !!str\n  1\n")).to eq({ "a" => "1" })
    end
  end

  describe "directives" do
    it "accepts a %YAML directive for a 1.x version" do
      expect(parse("%YAML 1.2\n---\na: 1\n")).to eq({ "a" => 1 })
      expect(parse("%YAML 1.1\n---\na: 1\n")).to eq({ "a" => 1 })
    end

    it "refuses a %YAML directive for another major version" do
      expect { parse("%YAML 2.0\n---\na: 1\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "refuses a repeated %YAML directive in one document" do
      expect { parse("%YAML 1.2\n%YAML 1.2\n---\na: 1\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "expands a handle a %TAG directive defines" do
      expect(parse("%TAG !e! tag:example.com,2020:\n---\na: !e!thing 1\n")).to eq({ "a" => 1 })
      expect(parse("%TAG ! tag:example.com,2020:\n---\na: !thing 1\n")).to eq({ "a" => 1 })
    end

    it "lets a %TAG directive redirect the core schema handle" do
      expect(parse("%TAG !! tag:yaml.org,2002:\n---\na: !!str 1\n")).to eq({ "a" => "1" })
    end

    it "refuses a handle no directive defined" do
      expect { parse("a: !e!thing 1\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "refuses a %TAG directive with the wrong number of arguments" do
      expect { parse("%TAG !e!\n---\na: 1\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "refuses the same handle defined twice in one document" do
      expect { parse("%TAG !e! tag:a:\n%TAG !e! tag:b:\n---\na: 1\n") }
        .to raise_error(YAMLCamel::SyntaxError)
    end

    it "ignores a directive it does not know" do
      expect(parse("%FOO bar\n---\na: 1\n")).to eq({ "a" => 1 })
    end

    it "refuses a directive that no '---' marker follows" do
      expect { parse("%YAML 1.2\na: 1\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "does not carry a handle across a document boundary" do
      text = "%TAG !e! tag:example.com,2020:\n---\na: !e!thing 1\n---\nb: !e!thing 2\n"
      expect { YAMLCamel::Parser.parse_stream(text) }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "percent decodes a tag suffix" do
      expect(parse("%TAG !e! tag:example.com,2020:\n---\na: !e!a%20b 1\n")).to eq({ "a" => 1 })
    end

    it "refuses a verbatim tag that never closes" do
      expect { parse("a: !<tag:example.com 1\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("a: !<> 1\n") }.to raise_error(YAMLCamel::SyntaxError)
    end
  end
end
