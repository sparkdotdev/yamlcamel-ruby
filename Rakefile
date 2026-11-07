require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Fail if a typographic dash appears anywhere in the repository"
task :punctuation do
  # Written as escapes so this file does not itself trip the check it performs.
  dashes = { "em dash" => "\u2014", "en dash" => "\u2013" }
  # The license and the conformance corpus are verbatim third-party text, so neither is ours to edit.
  exempt = ["LICENSE.MD", "spec/fixtures/yaml-test-suite/cases.json"]
  offenders = `git ls-files`.split("\n").flat_map do |file|
    next [] if exempt.include?(file)
    next [] unless File.file?(file)

    contents = File.read(file, encoding: "UTF-8")
    dashes.filter_map { |name, char| "#{file} (#{name})" if contents.include?(char) }
  end
  abort("Typographic dashes found:\n  #{offenders.join("\n  ")}") if offenders.any?
  puts "No typographic dashes."
end

desc "Fuzz the parser for FUZZ_SECONDS (default 60), seeded from the corpus"
task :fuzz do
  $LOAD_PATH.unshift(File.expand_path("lib", __dir__), File.expand_path("spec", __dir__))
  require "support/fuzzer"

  seconds = Integer(ENV.fetch("FUZZ_SECONDS", 60))
  seed = Integer(ENV.fetch("FUZZ_SEED", Random.new_seed % (2**32)))
  corpus = Dir[File.expand_path("spec/corpus/*.yaml", __dir__)].sort.map do |path|
    whole = File.binread(path).force_encoding(Encoding::UTF_8)
    whole[(whole.index("#!---\n") + 6)..]
  end

  puts "fuzzing for #{seconds}s from seed #{seed} over #{corpus.length} corpus files"
  fuzzer = YAMLCamelSpec::Fuzzer.new(seed: seed, corpus: corpus)
  findings = fuzzer.run(seconds: seconds)
  puts "#{fuzzer.attempts} inputs, #{findings.length} finding(s)"

  unless findings.empty?
    require "fileutils"
    FileUtils.mkdir_p("fuzz-findings")
    findings.each_with_index do |finding, index|
      File.binwrite("fuzz-findings/#{finding.kind}-#{finding.seed}-#{index}.yaml", finding.input.to_s)
      warn "#{finding.kind} seed #{finding.seed}: #{finding.detail}"
    end
    abort("fuzzing found #{findings.length} input(s) the parser did not answer cleanly")
  end
end

task default: %i[spec punctuation]
