# frozen_string_literal: true

require "stringio"
require "timeout"

RSpec.describe YAMLCamel::DocumentStream do
  def streamed(text, **options)
    documents = []
    YAMLCamel.each_document(text, **options) { |document| documents << document }
    documents
  end

  it "reads the documents of a stream in order" do
    expect(streamed("--- a\n--- b\n--- c\n")).to eq(%w[a b c])
  end

  it "agrees with reading the whole text at once" do
    ["a: 1\n", "--- a\n--- b\n", "a: 1\n---\nb: 2\n...\n---\nc: 3\n", "- 1\n- 2\n",
     "# comment only\n", "", "a: |\n  ---\n  not a marker\n", "%TAG !e! tag:x:\n---\na: !e!t 1\n"].each do |text|
      expect(streamed(text)).to eq(YAMLCamel.load_stream(text)), text.inspect
    end
  end

  it "does not depend on where a chunk boundary falls" do
    text = "--- a\n--- b\n...\n--- c\n"
    [1, 2, 3, 7, 4096].each do |size|
      documents = []
      stream = described_class.new { |document| documents << document }
      text.b.chars.each_slice(size) { |slice| stream.push(slice.join) }
      stream.finish
      expect(documents).to eq(%w[a b c]), "chunk size #{size}"
    end
  end

  it "strips a byte order mark opening any document, not only the first" do
    text = "--- a\n...\n﻿b: 2\n"
    expect(streamed(text)).to eq(YAMLCamel.load_stream(text))
    expect(streamed(text).last).to eq({ "b" => 2 })
  end

  it "strips a byte order mark that opens a document even after a blank line or comment" do
    [
      "---\n\n﻿a: 1\n",
      "---\n# note\n﻿a: 1\n",
      "---\na: 1\n...\n\n﻿b: 2\n"
    ].each do |text|
      value = YAMLCamel.load_stream(text)
      expect(streamed(text)).to eq(value), text.inspect
      expect(value.last.keys.first).not_to start_with("﻿"), text.inspect
    end
  end

  it "agrees between a whole parse and every chunk size across a multi-document BOM-laden stream" do
    text = (1..8).map { |i| "﻿doc#{i}:\n  val: ﻿v#{i}\n  list:\n    - ﻿x#{i}\n    - y#{i}\n" }
                 .join("---\n")
    text = "#{text}\n"
    whole = YAMLCamel.load_stream(text)

    (1..300).each do |size|
      documents = []
      stream = described_class.new { |document| documents << document }
      text.b.chars.each_slice(size) { |slice| stream.push(slice.join) }
      stream.finish
      expect(documents).to eq(whole), "chunk size #{size}"
    end
  end

  it "treats a lone trailing byte order mark the same whether read whole or in chunks" do
    # A fuzz-found case: a bare byte order mark after a block scalar's '...' used to survive into a
    # second document only when the whole text reached the parser in one piece, since only the
    # first document had its marker stripped.
    text = "--- |\n%!PS-Adobe-2.0\n...\n\xEF\xBB\xBF".dup.force_encoding(Encoding::UTF_8)
    [1, 3, 7, 29, 4096].each do |size|
      expect(streamed(text)).to eq(YAMLCamel.load_stream(text))
      documents = []
      stream = described_class.new { |document| documents << document }
      text.b.chars.each_slice(size) { |slice| stream.push(slice.join) }
      stream.finish
      expect(documents).to eq(YAMLCamel.load_stream(text)), "chunk size #{size}"
    end
  end

  it "keeps a directive with the document it introduces" do
    expect(streamed("%TAG !e! tag:x:\n---\na: !e!thing 1\n---\nb: 2\n"))
      .to eq([{ "a" => 1 }, { "b" => 2 }])
  end

  it "keeps the comments and blank lines around a directive with it" do
    expect(streamed("%FOO bar # ignored\n  # with a warning\n---\n\"foo\"\n")).to eq(["foo"])
    expect(streamed("---\n1\n...\n# a note\n%TAG ! tag:x:\n---\n!t 2\n")).to eq([1, 2])
    expect(streamed("%YAML 1.2\n\t\n---\n")).to eq([nil])
  end

  it "answers the same way as reading the whole text for every corpus case" do
    Dir[File.expand_path("corpus/*.yaml", __dir__)].sort.each do |path|
      whole = File.binread(path).force_encoding(Encoding::UTF_8)
      text = whole[(whole.index("#!---\n") + 6)..]
      expect(outcome_of(text)).to eq(whole_outcome_of(text)), File.basename(path)
    end
  end

  def outcome_of(text)
    documents = []
    YAMLCamel.each_document(text) { |document| documents << document }
    documents.map { |document| YAMLCamel.dump(document, limits: YAMLCamel::EmitLimits.permissive) }
  rescue YAMLCamel::ParseError => e
    e.class.name
  end

  def whole_outcome_of(text)
    YAMLCamel.load_stream(text)
             .map { |document| YAMLCamel.dump(document, limits: YAMLCamel::EmitLimits.permissive) }
  rescue YAMLCamel::ParseError => e
    e.class.name
  end

  it "does not carry an anchor across a document boundary" do
    expect { streamed("--- &x 1\n--- *x\n") }.to raise_error(YAMLCamel::UndefinedAliasError)
  end

  it "spends one budget across the whole stream rather than one per document" do
    bomb = <<~YAML
      a: &a [x,x,x,x,x,x,x,x,x]
      b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]
      c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]
      d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c]
      e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d]
      f: &f [*e,*e,*e,*e,*e,*e,*e,*e,*e]
    YAML
    expect { streamed("---\n#{bomb}" * 64) }.to raise_error(YAMLCamel::TooManyNodesError)
  end

  it "bounds the bytes of the whole stream rather than of one document" do
    limits = YAMLCamel::Limits.default.with(max_input_bytes: 100)
    expect { streamed("--- a\n" * 100, limits: limits) }.to raise_error(YAMLCamel::InputTooLargeError)
  end

  it "bounds how many documents a stream may hold" do
    limits = YAMLCamel::Limits.default.with(max_documents: 3)
    expect { streamed("--- a\n" * 10, limits: limits) }.to raise_error(YAMLCamel::TooManyDocumentsError)
  end

  it "reads from an IO in chunks" do
    io = StringIO.new("--- a\n--- b\n")
    documents = []
    expect(YAMLCamel.each_document(io, chunk_size: 3) { |document| documents << document }).to eq(2)
    expect(documents).to eq(%w[a b])
  end

  it "stops on an IO that answers an empty read instead of nil" do
    # A device that never signals the end of its input. Nothing is ever pushed, so no byte total ever
    # grows and no bound in Limits could bring the loop to a stop on its own.
    endless = Class.new do
      def read(_size = nil) = ""
    end.new

    expect(Timeout.timeout(10) { YAMLCamel.each_document(endless) { |_d| nil } }).to eq(0)
  end

  it "reads an IO that answers an empty read part way through" do
    stuttering = Class.new do
      def initialize = @chunks = ["--- a\n", "", "--- b\n"]
      def read(_size = nil) = @chunks.shift
    end.new

    documents = []
    Timeout.timeout(10) { YAMLCamel.each_document(stuttering) { |document| documents << document } }
    expect(documents).to eq(["a"])
  end

  it "refuses a push from a thread other than the one that started the stream" do
    stream = described_class.new { |_document| nil }
    stream.push("--- a\n")

    caught = nil
    Thread.new do
      stream.push("--- b\n")
    rescue StandardError => e
      caught = e
    end.join

    expect(caught).to be_a(YAMLCamel::CrossThreadUsageError)
  end

  it "refuses a finish from a thread other than the one that started the stream" do
    stream = described_class.new { |_document| nil }
    stream.push("--- a\n")

    caught = nil
    Thread.new do
      stream.finish
    rescue StandardError => e
      caught = e
    end.join

    expect(caught).to be_a(YAMLCamel::CrossThreadUsageError)
  end

  it "raises immediately instead of corrupting data when several threads push into one shared stream" do
    # Regression test for the concurrent-push race: 12 threads pushing into one shared stream used
    # to produce wrong document counts and corrupted content, every run. The fix refuses every
    # thread but the first outright.
    documents = []
    documents_mutex = Mutex.new
    stream = described_class.new { |document| documents_mutex.synchronize { documents << document } }

    errors = Queue.new
    threads = Array.new(12) do |t|
      Thread.new do
        1000.times { |i| stream.push("--- t#{t}i#{i}\n") }
      rescue StandardError => e
        errors << e
      end
    end
    threads.each(&:join)
    caught = Array.new(errors.size) { errors.pop }

    expect(caught).not_to be_empty
    expect(caught).to all(be_a(YAMLCamel::CrossThreadUsageError))
    documents.each { |document| expect(document).to match(/\At\d+i\d+\z/) }
    expect(documents.uniq.length).to eq(documents.length)
  end

  it "holds no more than the document it is reading" do
    stream = described_class.new { |_document| nil }
    stream.push("--- #{"x" * 100_000}\n")
    buffer = stream.instance_variable_get(:@buffer)
    expect(buffer.bytesize).to be > 50_000
    stream.push("--- small\n")
    expect(stream.instance_variable_get(:@buffer).bytesize).to be < 1_000
  end
end
