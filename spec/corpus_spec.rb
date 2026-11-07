# frozen_string_literal: true

# Walks every file in spec/corpus and holds each one to the same contract.
#
# The corpus accumulates: every crash, hang or wrong round trip found in development becomes a file
# there, so a later change cannot quietly bring it back. A file starts with a '#!' note saying what
# it is, then a '#!---' line, then the input. The set is shared with the Swift and Lua siblings.
RSpec.describe "corpus" do
  Case = Struct.new(:name, :note, :text)

  # Read as raw bytes, because some cases are not valid UTF-8 on purpose.
  def self.cases
    @cases ||= Dir[File.expand_path("corpus/*.yaml", __dir__)].sort.map do |path|
      whole = File.binread(path).force_encoding(Encoding::UTF_8)
      separator = whole.index("#!---\n")
      raise "#{path} has no '#!---' separator" if separator.nil?

      note = whole[0...separator].lines.filter_map { |line| line[3..]&.strip if line.start_with?("#! ") }
      raise "#{path} has no note saying what it is" if note.empty?

      Case.new(File.basename(path, ".yaml"), note.join(" "), whole[(separator + 6)..])
    end
  end

  def cases = self.class.cases

  it "holds more than twenty cases" do
    expect(cases.length).to be > 20
  end

  it "answers every case with a value or a ParseError, and nothing else" do
    cases.each do |item|
      YAMLCamel.load_stream(item.text)
    rescue YAMLCamel::ParseError
      next
    rescue StandardError => e
      raise "#{item.name} raised #{e.class} rather than a ParseError: #{e.message}"
    end
  end

  it "answers every case the same way twice" do
    cases.each do |item|
      first = outcome_of(item.text)
      second = outcome_of(item.text)
      expect(second).to eq(first), "#{item.name} behaved differently on the second run"
    end
  end

  it "round trips every case that parses" do
    cases.each do |item|
      documents = begin
        YAMLCamel.load_stream(item.text)
      rescue YAMLCamel::ParseError
        next
      end

      documents.each do |document|
        # Compared as text, since a document holding a NaN is never equal to itself, and on
        # permissive limits, since an aliased document can emit past the bound it parsed under.
        emitted = YAMLCamel.dump(document, limits: YAMLCamel::EmitLimits.permissive)
        back = YAMLCamel.load(emitted, limits: YAMLCamel::Limits.permissive)
        expect(YAMLCamel.dump(back, limits: YAMLCamel::EmitLimits.permissive)).to eq(emitted),
                                                                                  "#{item.name} changed value through emit and parse"
      end
    end
  end

  REFUSALS = {
    "nested-flow-1000" => YAMLCamel::DepthExceededError,
    "nested-flow-2000" => YAMLCamel::DepthExceededError,
    "nested-flow-32000" => YAMLCamel::DepthExceededError,
    "nested-flow-mappings" => YAMLCamel::DepthExceededError,
    "nested-block-sequences" => YAMLCamel::DepthExceededError,
    "billion-laughs" => YAMLCamel::TooManyNodesError,
    "alias-bomb-once-per-document" => YAMLCamel::TooManyNodesError,
    "alias-bomb-once-per-sequence-item" => YAMLCamel::TooManyNodesError,
    "many-documents" => YAMLCamel::TooManyDocumentsError,
    "alias-to-undefined-anchor" => YAMLCamel::UndefinedAliasError,
    "alias-across-documents" => YAMLCamel::UndefinedAliasError,
    "self-referential-alias" => YAMLCamel::UndefinedAliasError,
    "duplicate-key-block" => YAMLCamel::DuplicateKeyError,
    "duplicate-key-flow" => YAMLCamel::DuplicateKeyError
  }.freeze

  SYNTAX_ERRORS = %w[
    unterminated-flow-sequence unterminated-flow-mapping unterminated-double-quote
    unterminated-single-quote truncated-after-directive stray-backslash-at-end
    over-indented-continuation content-after-document leading-empty-line-over-indented
    lone-surrogate-escape quadratic-flow-rescan
  ].freeze

  # Cases the siblings refuse on their own tighter depth ceiling and this one accepts, since 256
  # levels is what a Ruby stack takes rather than the 48 a Swift cooperative thread does.
  WITHIN_THE_CEILING = %w[alternating-sequence-mapping deep-alias-chain].freeze

  it "refuses the cases named as limit refusals" do
    REFUSALS.each do |name, error|
      expect { YAMLCamel.load_stream(named(name).text) }.to raise_error(error), name
    end
  end

  it "reports the cases named as syntax errors" do
    SYNTAX_ERRORS.each do |name|
      expect { YAMLCamel.load_stream(named(name).text) }.to raise_error(YAMLCamel::SyntaxError), name
    end
  end

  it "accepts the deep cases that sit inside this library's own ceiling" do
    WITHIN_THE_CEILING.each do |name|
      expect { YAMLCamel.load_stream(named(name).text) }.not_to raise_error
    end
  end

  it "reads a block scalar's content rather than its own header" do
    expect(YAMLCamel.load(named("block-scalar-as-sequence-item").text)).to eq(["hello\n"])
    expect(YAMLCamel.load(named("block-scalar-at-document-root").text)).to eq("hello\n")
  end

  it "carries a byte order mark inside a scalar through a round trip" do
    %w[bom-in-quoted-scalar bom-as-mapping-key bom-mid-key].each do |name|
      value = YAMLCamel.load(named(name).text)
      expect(YAMLCamel.load(YAMLCamel.dump(value))).to eq(value), "#{name} lost its mark"
    end
  end

  it "strips a byte order mark that opens a document even after a blank line" do
    value = YAMLCamel.load(named("bom-after-blank-line").text)
    expect(value).to eq({ "a" => 1 })
  end

  it "refuses bytes that are not valid UTF-8 with its own syntax error" do
    expect { YAMLCamel.load_stream(named("malformed-utf8").text) }.to raise_error(YAMLCamel::SyntaxError)
  end

  def named(name)
    found = cases.find { |item| item.name == name }
    raise "corpus case #{name} is missing" if found.nil?

    found
  end

  def outcome_of(text)
    YAMLCamel.load_stream(text).map { |document| YAMLCamel.dump(document, limits: YAMLCamel::EmitLimits.permissive) }
  rescue YAMLCamel::ParseError => e
    "#{e.class}: #{e.message}"
  end
end
