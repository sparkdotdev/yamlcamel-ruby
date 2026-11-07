# frozen_string_literal: true

require "support/fuzzer"

# A short, fixed-seed run of the same harness the CI fuzz job runs for minutes, so the harness itself
# is covered by the ordinary suite and a finding it would report fails the build here too.
RSpec.describe YAMLCamelSpec::Fuzzer do
  def corpus
    @corpus ||= Dir[File.expand_path("corpus/*.yaml", __dir__)].sort.map do |path|
      whole = File.binread(path).force_encoding(Encoding::UTF_8)
      whole[(whole.index("#!---\n") + 6)..]
    end
  end

  it "answers every mutated input with a value or one of its own errors" do
    fuzzer = described_class.new(seed: 0x59414D4C, corpus: corpus)
    findings = fuzzer.run(iterations: 1_500)
    expect(fuzzer.attempts).to eq(1_500)
    expect(findings.map { |finding| "#{finding.kind} seed #{finding.seed}: #{finding.detail}" })
      .to be_empty
  end

  it "reports a hang rather than waiting for one" do
    fuzzer = described_class.new(seed: 1, corpus: [], attempt_timeout: 0.1)
    allow(YAMLCamel).to receive(:load_stream) { sleep(5) }
    fuzzer.attempt(1)
    expect(fuzzer.findings.map(&:kind)).to eq([:hang])
  end

  it "reports anything that is not one of this library's own errors" do
    fuzzer = described_class.new(seed: 1, corpus: [])
    allow(YAMLCamel).to receive(:load_stream).and_raise(NoMethodError, "boom")
    fuzzer.attempt(1)
    expect(fuzzer.findings.map(&:kind)).to eq([:leaked])
  end
end
