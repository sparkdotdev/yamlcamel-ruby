# frozen_string_literal: true
require "spec_helper"

RSpec.describe "Boundary and round-trip regressions" do
  let(:codec) { YAMLCamel::IO::GzipCompression.new }

  it "decodes concatenated gzip members across every input boundary" do
    bytes = codec.compress("safe: 1\n") + codec.compress("next: 2\n")
    (0..bytes.bytesize).each do |split|
      worker = codec.decompressor
      text = worker.push(bytes.byteslice(0, split)) + worker.push(bytes.byteslice(split..)) + worker.finish
      expect(text).to eq("safe: 1\nnext: 2\n")
    end
  end

  it "refuses uncompressed suffixes and incomplete later gzip members" do
    member = codec.compress("safe: 1\n")
    ["admin: true\n", "\x1f".b, codec.compress("next: 2\n")[0...-2]].each do |suffix|
      expect { codec.decompress(member + suffix) }.to raise_error(YAMLCamel::CompressionError)
      worker = codec.decompressor
      worker.push(member)
      expect { worker.push(suffix); worker.finish }.to raise_error(YAMLCamel::CompressionError)
    end
  end

  it "charges output from all compressed members to one budget" do
    bytes = codec.compress("x" * 60) + codec.compress("y" * 60)
    expect { codec.decompress(bytes, max_output_bytes: 100) }.to raise_error(YAMLCamel::InflatedTooLargeError)
  end

  it "refuses an oversized flow key before traversing its remaining nodes" do
    key = ["x" * 1024, Object.new]
    limits = YAMLCamel::EmitLimits.default.with(max_output_bytes: 64)
    [false, true].each do |sorted|
      expect { YAMLCamel.dump({ key => 1 }, limits: limits, sort_keys: sorted) }
        .to raise_error(YAMLCamel::OutputTooLargeError)
    end
  end

  it "round-trips nested collection keys and refuses ambiguous keys inside them" do
    value = { ["a", { "b" => [1, 2] }] => 3 }
    expect(YAMLCamel.load_one(YAMLCamel.dump(value))).to eq(value)
    expect { YAMLCamel.dump({ [{ :a => 1, "a" => 2 }] => 3 }) }.to raise_error(YAMLCamel::AmbiguousKeyError)
  end

  it "reads repeated escapes mixed with Unicode without recounting the growing string" do
    text = '"' + ('é\\n' * 200_000) + '"'
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect(YAMLCamel.load_one(text)).to eq("é\n" * 200_000)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
  end
  it "rejects invalid bytes and raw controls, and escapes nonprintable Unicode" do
    expect { YAMLCamel.load("a\0b") }.to raise_error(YAMLCamel::SyntaxError)
    expect { YAMLCamel.load("\xFF".b) }.to raise_error(YAMLCamel::SyntaxError)
    ["\u0080", "\u009F", "\uFFFE", "\uFFFF"].each do |value|
      emitted = YAMLCamel.dump(value)
      expect(emitted).to start_with('"\\u')
      expect(YAMLCamel.load_one(emitted)).to eq(value)
    end
  end

  it "charges document framing and empty roots to emission budgets" do
    expect { YAMLCamel.dump_stream(nil, limits: YAMLCamel::EmitLimits.new(max_output_bytes: 5)) }
      .to raise_error(YAMLCamel::OutputTooLargeError)
    [[], {}].each do |root|
      expect { YAMLCamel.dump(root, limits: YAMLCamel::EmitLimits.new(max_nodes: 0)) }
        .to raise_error(YAMLCamel::EmitTooManyNodesError)
    end
  end

  it "distinguishes raw printable contexts from quoted JSON characters" do
    [0x7F, 0x80, 0x9F, 0xFFFE, 0xFFFF].each do |code|
      raw = code.chr(Encoding::UTF_8)
      [raw, "key: #{raw}", "key: |\n  #{raw}\n", "# #{raw}", "&a#{raw} value", "!tag#{raw} value", "%TAG !t! tag:#{raw}\n---\nvalue"].each do |input|
        expect { YAMLCamel.load_one(input) }.to raise_error(YAMLCamel::SyntaxError), input
      end
      expect(YAMLCamel.load_one('"' + raw + '"')).to eq(raw)
      expect(YAMLCamel.load_one("'" + raw + "'")).to eq(raw)
      expect(YAMLCamel.load_one(format('"\\u%04X"', code))).to eq(raw)
    end
    expect(YAMLCamel.load_one("a\u0085b")).to eq("a\u0085b")
  end

  it "checks escaped continuations while preserving root and content-tab rules" do
    ["key: \"one\\\ntwo\"", "key: \"one\\\n---\nend\"", "a:\n\tb: 1\n", " \t- one", "\uFEFF \t- one"].each do |input|
      expect { YAMLCamel.load_one(input) }.to raise_error(YAMLCamel::SyntaxError)
    end
    expect(YAMLCamel.load_one("  \"one\ntwo\"")).to eq("one two")
    expect(YAMLCamel.load_one("key:\n   \"one\n \ttwo\"")["key"]).to eq("one two")
    expect(YAMLCamel.load_one("key: |2\n  \tcontent\n")["key"]).to eq("\tcontent\n")
  end

  it "counts actual block scalar content breaks and ignores unterminated EOF indentation" do
    ["|", ">"].each do |style|
      ["", "+", "-"].each do |chomp|
        head = "key: #{style}#{chomp}\n"
        expect(YAMLCamel.load_one(head + "  a")["key"]).to eq("a")
        expect(YAMLCamel.load_one(head + "  a\n\n  ")["key"])
          .to eq(chomp == "+" ? "a\n\n" : chomp == "-" ? "a" : "a\n")
        expect(YAMLCamel.load_one(head + "  ")["key"]).to eq("")
      end
    end
  end

end
