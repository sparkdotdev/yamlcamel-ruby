# frozen_string_literal: true

require "json"

# Runs the official yaml-test-suite (https://github.com/yaml/yaml-test-suite) against this parser.
#
# spec/fixtures/yaml-test-suite/cases.json is generated from the suite's src/*.yaml files: each entry
# holds the input, whether it is expected to fail, and, when the suite gives one, the expected value
# as one JSON text per document in the stream. The same fixture is shared with the Swift sibling.
RSpec.describe "yaml-test-suite conformance" do
  # The suite checks the grammar rather than a schema, and it has cases whose trees repeat a mapping
  # key. Duplicate handling is a policy this library exposes, so conformance runs on the policy that
  # keeps every case readable and the default stays a refusal.
  LIMITS = YAMLCamel::Limits.default.with(duplicate_keys: :last_wins)

  # Cases this parser does not match the suite on, each with the reason.
  EXCLUDED = {
    "ZYU8-2" => "the suite wants '%YAML 1.1 1.2' accepted and H7TQ wants '%YAML 1.2 foo' refused, " \
                "and both are a version followed by an extra word"
  }.freeze

  def self.cases
    @cases ||= JSON.parse(File.read(File.expand_path("fixtures/yaml-test-suite/cases.json", __dir__)))
  end

  def cases = self.class.cases

  # Keys in the suite's JSON are always strings, so a key of another type compares by its own text.
  def comparable(value)
    case value
    when Hash then value.to_h { |key, item| [comparable_key(key), comparable(item)] }
    when Array then value.map { |item| comparable(item) }
    else value
    end
  end

  def comparable_key(key)
    case key
    when String then key
    when nil then ""
    when Array, Hash then key.inspect
    else key.to_s
    end
  end

  def same?(mine, theirs)
    if mine.is_a?(Array) && theirs.is_a?(Array)
      return mine.length == theirs.length && mine.zip(theirs).all? { |a, b| same?(a, b) }
    end
    if mine.is_a?(Hash) && theirs.is_a?(Hash)
      return mine.length == theirs.length &&
             mine.all? { |key, value| theirs.key?(key) && same?(value, theirs[key]) }
    end
    return mine == theirs if mine.is_a?(Numeric) && theirs.is_a?(Numeric)

    mine.class == theirs.class && mine == theirs
  end

  # Compares one case against the suite and returns nil when it agrees, or why it did not.
  def check(item)
    documents = begin
      YAMLCamel.load_stream(item["yaml"], limits: LIMITS)
    rescue YAMLCamel::ParseError => e
      return item["fail"] ? nil : "expected to parse but raised #{e.message}"
    end
    return "expected a parse failure but it parsed" if item["fail"]

    expected = item["expectedJSON"]
    return nil if expected.nil?
    return "expected #{expected.length} documents, got #{documents.length}" if
      documents.length != expected.length

    documents.zip(expected).each do |document, json|
      wanted = begin
        JSON.parse(json, allow_nan: true, allow_duplicate_key: true)
      rescue JSON::ParserError
        # A few expected values hold an infinity or a not-a-number, which JSON has no spelling for.
        next
      end
      next if same?(comparable(document), wanted)

      return "value #{comparable(document).inspect} does not match expected #{json}"
    end
    nil
  end

  it "holds the whole suite" do
    expect(cases.length).to be > 400
  end

  it "agrees with the suite on every case that is not excluded" do
    failures = cases.filter_map do |item|
      next if EXCLUDED.key?(item["id"])

      reason = begin
        check(item)
      rescue StandardError => e
        "raised #{e.class}: #{e.message}"
      end
      "#{item["id"]} (#{item["name"]}): #{reason}" if reason
    end

    expect(failures).to be_empty, -> { "#{failures.length} case(s) failed:\n#{failures.join("\n")}" }
  end

  it "answers every case with a value or one of its own errors, whatever the suite expects" do
    cases.each do |item|
      YAMLCamel.load_stream(item["yaml"], limits: LIMITS)
    rescue YAMLCamel::ParseError
      next
    rescue StandardError => e
      raise "#{item["id"]} raised #{e.class}: #{e.message}"
    end
  end

  it "reads back what it emitted for every case that parses" do
    cases.each do |item|
      documents = begin
        YAMLCamel.load_stream(item["yaml"], limits: LIMITS)
      rescue YAMLCamel::ParseError
        next
      end

      documents.each do |document|
        emitted = YAMLCamel.dump(document)
        back = YAMLCamel.load(emitted, limits: LIMITS)
        expect(YAMLCamel.dump(back)).to eq(emitted), "#{item["id"]} changed value through emit and parse"
      end
    end
  end

  it "reports the share of the suite it passes" do
    passed = cases.count { |item| EXCLUDED.key?(item["id"]) ? false : check(item).nil? }
    share = 100.0 * passed / cases.length
    expect(share).to be >= 99.7, "conformance fell to #{share.round(1)}%"
  end
end
