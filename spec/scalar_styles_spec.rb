# frozen_string_literal: true

RSpec.describe YAMLCamel::Parser do
  def parse(text) = described_class.parse(text)

  describe "plain scalars" do
    it "resolves against the core schema" do
      expect(parse("hello")).to eq("hello")
      expect(parse("17")).to eq(17)
      expect(parse("true")).to be(true)
      expect(parse("~")).to be_nil
      expect(parse("")).to be_nil
    end

    it "folds a continuation line onto the line before it" do
      expect(parse("plain\n  continued\n")).to eq("plain continued")
    end

    it "turns a blank line inside a plain scalar into a line break" do
      expect(parse("plain\n\n  continued\n")).to eq("plain\ncontinued")
    end

    it "drops the white space around each folded line" do
      expect(parse("plain   \n     continued   \n")).to eq("plain continued")
    end

    it "ends at a comment that follows white space" do
      expect(parse("plain # comment\n")).to eq("plain")
      expect(parse("plain#not-a-comment\n")).to eq("plain#not-a-comment")
    end

    it "keeps a colon that is not followed by a space" do
      expect(parse("12:30:00")).to eq("12:30:00")
    end

    it "refuses to start on an indicator character" do
      ["@x", "`x", "%x"].each do |text|
        expect { parse(text) }.to raise_error(YAMLCamel::SyntaxError)
      end
    end
  end

  describe "single-quoted scalars" do
    it "reads a doubled quote as one quote" do
      expect(parse("'single ''quoted'' text'")).to eq("single 'quoted' text")
    end

    it "leaves a backslash alone" do
      expect(parse("'a\\nb'")).to eq("a\\nb")
    end

    it "folds across lines" do
      expect(parse("'one\n  two'")).to eq("one two")
      expect(parse("'one\n\n  two'")).to eq("one\ntwo")
    end

    it "reports an unterminated scalar" do
      expect { parse("'unterminated") }.to raise_error(YAMLCamel::SyntaxError)
    end
  end

  describe "double-quoted scalars" do
    it "reads every escape the spec defines" do
      expect(parse('"\\0\\a\\b\\t\\n\\v\\f\\r\\e"')).to eq("\0\a\b\t\n\v\f\r\e")
      expect(parse('"\\ \\"\\/\\\\"')).to eq(" \"/\\")
      expect(parse('"\\N\\_\\L\\P"')).to eq("   ")
    end

    it "reads the hexadecimal escapes at all three widths" do
      expect(parse('"\\x41\\u00e9\\U0001F42B"')).to eq("Aé\u{1F42B}")
    end

    it "refuses an escape that is not a unicode scalar value" do
      expect { parse('"\\uD800"') }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse('"\\U00110000"') }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "refuses a hex escape with too few digits" do
      expect { parse('"\\x4"') }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "refuses an escape the spec does not define" do
      expect { parse('"\\q"') }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "refuses a stray backslash at the end of the input" do
      expect { parse('"abc\\') }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "folds across lines and joins on an escaped line break" do
      expect(parse("\"one\n  two\"")).to eq("one two")
      expect(parse("\"one \\\n  two\"")).to eq("one two")
    end

    it "keeps a trailing escaped tab that folding would otherwise trim" do
      expect(parse("\"one\\t\n  two\"")).to eq("one\t two")
      expect(parse("\"one\t\n  two\"")).to eq("one two")
    end
  end

  describe "block scalars" do
    it "keeps the line breaks of a literal block" do
      expect(parse("|\n  literal\n  lines\n")).to eq("literal\nlines\n")
    end

    it "folds the lines of a folded block" do
      expect(parse(">\n  folded\n  lines\n")).to eq("folded lines\n")
    end

    it "keeps a more indented line of a folded block verbatim" do
      expect(parse(">\n  folded\n   indented\n  back\n")).to eq("folded\n indented\nback\n")
    end

    it "applies every chomping indicator" do
      expect(parse("|\n  text\n\n\n")).to eq("text\n")
      expect(parse("|-\n  text\n\n\n")).to eq("text")
      expect(parse("|+\n  text\n\n\n")).to eq("text\n\n\n")
    end

    it "takes an explicit indentation indicator" do
      # Counted from the parent node's own indentation, which the spec's grammar puts at -1 for a
      # document root, so a root block scalar's content starts one column further left than libyaml
      # reads the same header.
      expect(parse("|2\n    text\n")).to eq("   text\n")
      expect(parse("|2-\n    text\n")).to eq("   text")
    end

    it "does not add a final line break the input never had" do
      expect(parse("|\n  text")).to eq("text")
      expect(parse("|+\n  text")).to eq("text")
      expect(parse(">\n  text")).to eq("text")
      expect(parse("|\n  one\n  two")).to eq("one\ntwo")
      expect(parse("|\n  text\n")).to eq("text\n")
    end

    it "keeps an empty line inside the block" do
      expect(parse("|\n  a\n\n  b\n")).to eq("a\n\nb\n")
    end

    it "reads an empty block as an empty string" do
      expect(parse("|\n")).to eq("")
      expect(parse("|+\n\n")).to eq("\n")
    end

    it "refuses a header it does not understand" do
      expect { parse("|x\n  a\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("|--\n  a\n") }.to raise_error(YAMLCamel::SyntaxError)
      expect { parse("| text\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "takes a comment on the header line" do
      expect(parse("| # note\n  a\n")).to eq("a\n")
    end

    it "refuses a leading empty line indented past the content" do
      expect { parse("|\n      \n  text\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "does not resolve its body against the core schema" do
      expect(parse("|-\n  123\n")).to eq("123")
      expect(parse("|-\n  null\n")).to eq("null")
    end
  end

  describe "streams" do
    it "reads an empty stream as no documents" do
      expect(described_class.parse_stream("")).to eq([])
      expect(described_class.parse_stream("# only a comment\n")).to eq([])
      expect(parse("")).to be_nil
    end

    it "reads the documents of a stream in order" do
      expect(described_class.parse_stream("--- one\n--- two\n")).to eq(%w[one two])
    end

    it "reads an explicit empty document" do
      expect(described_class.parse_stream("---\n...\n")).to eq([nil])
    end

    it "refuses a stream of several documents where one was asked for" do
      expect { parse("--- one\n--- two\n") }.to raise_error(YAMLCamel::DocumentCountError)
    end

    it "refuses content after a document with no marker between them" do
      expect { described_class.parse_stream("one\ntwo: 2\n") }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "strips a byte order mark that opens the stream" do
      expect(parse("﻿hello")).to eq("hello")
    end

    it "reads all three spellings of a line break the same way" do
      expect(parse("a\n  b\n")).to eq("a b")
      expect(parse("a\r\n  b\r\n")).to eq("a b")
      expect(parse("a\r  b\r")).to eq("a b")
    end

    it "refuses text that is not valid UTF-8 with a parse error" do
      expect { parse("\xFF\xFE abc".dup.force_encoding(Encoding::ASCII_8BIT)) }.to raise_error(YAMLCamel::SyntaxError)
    end

    it "reads from an IO the same way it reads from a string" do
      require "stringio"
      expect(described_class.parse_stream(StringIO.new("--- one\n--- two\n"))).to eq(%w[one two])
    end
  end
end
