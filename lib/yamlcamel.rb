# frozen_string_literal: true

require_relative "yamlcamel/version"
require_relative "yamlcamel/errors"
require_relative "yamlcamel/limits"
require_relative "yamlcamel/chars"
require_relative "yamlcamel/scalar"
require_relative "yamlcamel/tag"
require_relative "yamlcamel/parser"
require_relative "yamlcamel/emitter"
require_relative "yamlcamel/stream"
require_relative "yamlcamel/io/media_type"
require_relative "yamlcamel/io/storage"
require_relative "yamlcamel/io/compression"
require_relative "yamlcamel/io/transport"
require_relative "yamlcamel/files"
require_relative "yamlcamel/http"

# A pure Ruby implementation of YAML 1.2.2.
#
# Documents read as plain Ruby objects: Hash, Array, String, Integer, Float, true, false and nil.
# Nothing else is ever built, so a document from an untrusted source cannot name a class to
# instantiate the way a fuller schema allows.
module YAMLCamel
  class << self
    # Reads the first document of a stream. Returns nil for a stream with no documents.
    def load(input, limits: Limits.default)
      Parser.parse_stream(input, limits: limits).first
    end

    # Every load here builds core schema types only, so this is the same call as #load and exists for
    # code moving over from a library where the two differ.
    alias safe_load load

    # Reads every document of a stream and returns one value per document, in order.
    def load_stream(input, limits: Limits.default)
      Parser.parse_stream(input, limits: limits)
    end

    # Reads a stream that holds exactly one document. Raises DocumentCountError when it holds more.
    def load_one(input, limits: Limits.default)
      Parser.parse(input, limits: limits)
    end

    # Writes one value as a YAML document. Pass an IO to write into it and get it back, or leave it
    # out for the text.
    def dump(object, io = nil, sort_keys: false, limits: EmitLimits.default)
      text = Emitter.emit(object, sort_keys: sort_keys, limits: limits)
      return text if io.nil?

      io.write(text)
      io
    end

    # Writes several values as one stream, each with its own '---' marker.
    def dump_stream(*objects, sort_keys: false, limits: EmitLimits.default)
      emitter = Emitter.new(sort_keys: sort_keys, limits: limits)
      objects.map { |object| emitter.emit(object, document_marker: true) }.join
    end
  end
end
