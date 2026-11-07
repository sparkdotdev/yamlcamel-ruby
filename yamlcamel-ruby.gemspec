require_relative "lib/yamlcamel/version"

Gem::Specification.new do |spec|
  spec.name = "yamlcamel-ruby"
  spec.version = YAMLCamel::VERSION
  spec.authors = ["mszaro"]
  spec.summary = "A pure Ruby implementation of the YAML 1.2.2 spec"
  spec.homepage = "https://github.com/sparkdotdev/yamlcamel-ruby"
  spec.licenses = ["PolyForm-Noncommercial-1.0.0", "PolyForm-Small-Business-1.0.0"]
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "LICENSE.MD", "README.md", "CONTRIBUTING.md", "LICENSE-THIRD-PARTY.txt", "licenses/*.txt"]
  spec.require_paths = ["lib"]

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["license_expression"] = "PolyForm-Noncommercial-1.0.0 OR PolyForm-Small-Business-1.0.0"

  # Ruby 4.0 no longer ships rake as a default gem, so the Rakefile needs it named here.
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  # Only the default HTTP transport needs it, and only when a caller keeps that default.
  spec.add_development_dependency "faraday", "~> 2.9"
end
