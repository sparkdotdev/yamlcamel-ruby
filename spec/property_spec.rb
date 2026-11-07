# frozen_string_literal: true

require "support/generator"

RSpec.describe "generated properties" do
  # Changing this changes every generated case, so a run that failed can be reproduced by setting it
  # back. Nothing here reads the clock or an unseeded source.
  BASE_SEED = 0x59414D4C43414D

  def seed_for(property, index) = BASE_SEED + (property * 1_000_000) + index

  # Compared as text, since a value holding a NaN is never equal to itself.
  def same_value?(left, right)
    YAMLCamel.dump(left) == YAMLCamel.dump(right)
  end

  it "reads back anything the emitter writes to an equal value" do
    2_000.times do |index|
      seed = seed_for(1, index)
      original = YAMLCamelSpec::Generator.new(seed).value
      text = YAMLCamel.dump(original)
      reparsed = YAMLCamel.load(text)
      next if same_value?(original, reparsed)

      raise "round trip changed the value, seed #{seed}\noriginal: #{original.inspect}\n" \
            "emitted:\n#{text}reparsed: #{reparsed.inspect}"
    end
  end

  it "writes what it read back the same way a second time" do
    1_000.times do |index|
      seed = seed_for(2, index)
      original = YAMLCamelSpec::Generator.new(seed).value
      once = YAMLCamel.dump(original)
      twice = YAMLCamel.dump(YAMLCamel.load(once))
      raise "emit was not stable, seed #{seed}\nfirst:\n#{once}second:\n#{twice}" unless once == twice
    end
  end

  it "sorts keys without changing the value" do
    500.times do |index|
      seed = seed_for(3, index)
      original = YAMLCamelSpec::Generator.new(seed).value
      sorted = YAMLCamel.load(YAMLCamel.dump(original, sort_keys: true))
      next if same_value?(YAMLCamel.load(YAMLCamel.dump(original)), sorted) ||
              sorted.is_a?(Hash) || sorted.is_a?(Array)

      raise "sorting changed the value, seed #{seed}"
    end
  end

  it "answers byte soup with a value or one of its own errors, never anything else" do
    3_000.times do |index|
      seed = seed_for(4, index)
      generator = YAMLCamelSpec::Generator.new(seed)
      text = generator.boolean ? generator.soup : generator.bytes
      begin
        YAMLCamel.load_stream(text)
      rescue YAMLCamel::Error
        nil
      rescue StandardError => e
        raise "soup raised #{e.class}, seed #{seed}: #{e.message}\ninput: #{text.inspect}"
      end
    end
  end

  it "answers the same input the same way twice" do
    1_000.times do |index|
      seed = seed_for(5, index)
      text = YAMLCamelSpec::Generator.new(seed).soup
      first = begin
        YAMLCamel.load_stream(text).inspect
      rescue YAMLCamel::Error => e
        "#{e.class}: #{e.message}"
      end
      second = begin
        YAMLCamel.load_stream(text).inspect
      rescue YAMLCamel::Error => e
        "#{e.class}: #{e.message}"
      end
      raise "parsing was not deterministic, seed #{seed}" unless first == second
    end
  end

  it "reads back anything the emitter writes for a stream of several documents" do
    300.times do |index|
      seed = seed_for(6, index)
      generator = YAMLCamelSpec::Generator.new(seed)
      documents = Array.new(1 + generator.integer(0..3)) { generator.value }
      text = YAMLCamel.dump_stream(*documents)
      back = YAMLCamel.load_stream(text)
      next if back.length == documents.length &&
              documents.zip(back).all? { |left, right| same_value?(left, right) }

      raise "stream round trip changed the value, seed #{seed}\n#{text}"
    end
  end
end
