# YAMLCamel for Ruby

YAMLCamel reads and writes YAML in pure Ruby. It turns documents into ordinary Ruby values and can process streams one document at a time. File, gzip and HTTP helpers sit behind interfaces you can replace with your own.

Copyright 2026, Spark Software Development, LLC.

## Features

Use `YAMLCamel.load` and `YAMLCamel.dump` for the usual configuration-file jobs. Mappings become hashes, sequences become arrays, and scalars use Ruby strings, numbers, booleans and `nil`; parsing does not instantiate application classes.

The parser targets [YAML 1.2.2](https://yaml.org/spec/1.2.2/) and handles block and flow collections, quoted and block strings, directives, anchors, aliases, and explicit tags. The YAML Test Suite is part of the tests, with one documented directive case excluded. `load_stream` reads a document stream, while `load_one` rejects input containing more than one document. The parser and emitter have no third-party runtime dependencies, so you can embed them in a Ruby application without adding another gem or a native parser.

Input and output limits let you put bounds on document size, nesting, node counts and alias use. Duplicate mapping keys are rejected by default, and callers can choose a different policy when reading data they control.

The file and HTTP helpers can read plain or gzip-compressed YAML. They accept replacement storage, compression and transport implementations, so the parser can fit into an existing filesystem or networking layer. The storage, compression and transport interfaces live under `lib/yamlcamel/io/`.

## Configuration

The library does not read environment variables. Pass options to the call or construct a limits object with the settings your input needs.

| Option | Purpose |
| --- | --- |
| `limits: YAMLCamel::Limits` | Parser bounds and duplicate-key policy; use `.default.with(...)` to change individual fields. |
| `limits: YAMLCamel::EmitLimits` | Output byte, node and nesting bounds for emitting. |
| `sort_keys:` | Sort mapping keys when writing YAML; defaults to `false`. |
| `storage:`, `compression:`, `transport:` | Replace the file, gzip or HTTP implementation on the relevant helper. |
| `transfer:` | Bound HTTP response and inflated body sizes with `YAMLCamel::IO::TransferLimits`. |

## Build & Deploy

Ruby 4.0 or newer is required. From a checkout, run `bundle install` and `bundle exec rake`; `gem build yamlcamel-ruby.gemspec` creates the gem without compiling a native extension. Require `yamlcamel` in the consuming application. The default HTTP transport needs Faraday, which the core parser does not require. Install a reviewed gem or pin a source revision when adding the library to an application.

## License

PolyForm Noncommercial 1.0.0 OR PolyForm Small Business 1.0.0, at your choice. Source-available, but not open-source. See [License](LICENSE.MD) for the full terms.

The Noncommercial option permits noncommercial use. The Small Business option also permits use for a company's benefit when it has fewer than 100 employees and independent contractors combined and less than USD 1,000,000 in prior-tax-year revenue, measured in 2019 dollars and adjusted for inflation as the licence specifies. Its company definition includes related organisations under common control. Both options permit modifications and redistribution for their permitted purposes, subject to their conditions.

## Forking and Contributions

The [License](LICENSE.MD) permits modifications, forks and redistribution for the permitted purposes of either option, subject to its conditions. Our [Contribution Policy](CONTRIBUTING.md) also grants additional permissions for contribution forks, review and controlled testing. The limits and deadlines on that additional permission do not narrow independent rights granted by the software licence, applicable law or the hosting platform's terms.

Contributions are welcome. You retain ownership, but Spark may use and commercially relicense submitted contributions, including under proprietary terms, even if a submission is declined or withdrawn. Read and accept the contribution agreement before submitting a change.
