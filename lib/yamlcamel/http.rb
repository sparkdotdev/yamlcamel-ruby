# frozen_string_literal: true

module YAMLCamel
  # Sends and receives YAML over HTTP.
  #
  # Every call takes a transport and a compression, both defaulting to Faraday and gzip. Pass your
  # own to route calls through another networking layer or codec: see YAMLCamel::IO::Transport and
  # YAMLCamel::IO::Compression.
  #
  # What comes back is checked before it is parsed: status, size while arriving, content type and
  # encoding, trusting a Content-Encoding header only when the bytes carry the codec's own signature.
  module HTTP
    # Guards the lazy defaults below against being built twice by two threads racing on the first
    # call. Set once at load time so the guard itself needs no guarding.
    DEFAULTS_MUTEX = Mutex.new
    private_constant :DEFAULTS_MUTEX

    class << self
      # Meant for one-time setup, generally at boot: reassigning either while other threads may
      # already be reading it races the same way any shared global does.
      attr_writer :transport, :compression

      def transport = @transport || DEFAULTS_MUTEX.synchronize { @transport ||= IO::FaradayTransport.new }

      def compression = @compression || DEFAULTS_MUTEX.synchronize { @compression ||= IO::GzipCompression.new }
    end

    module_function

    # Fetches a URL and returns the first document of the response.
    def get(url, headers: {}, limits: Limits.default, transfer: IO::TransferLimits.default,
            transport: HTTP.transport, compression: HTTP.compression,
            require_yaml_content_type: true)
      text = request(:get, url, headers: headers, transfer: transfer, transport: transport,
                                compression: compression,
                                require_yaml_content_type: require_yaml_content_type)
      YAMLCamel.load_stream(text, limits: limits).first
    end

    # Fetches a URL and returns every document of the response, in order.
    def get_stream(url, headers: {}, limits: Limits.default, transfer: IO::TransferLimits.default,
                   transport: HTTP.transport, compression: HTTP.compression,
                   require_yaml_content_type: true)
      text = request(:get, url, headers: headers, transfer: transfer, transport: transport,
                                compression: compression,
                                require_yaml_content_type: require_yaml_content_type)
      YAMLCamel.load_stream(text, limits: limits)
    end

    # Fetches a URL and yields each document of the response as it completes, returning how many
    # there were. The body is bounded and inflated below, then parsed a document at a time, so no
    # response is ever held whole.
    def each_document(url, headers: {}, limits: Limits.default, transfer: IO::TransferLimits.default,
                      transport: HTTP.transport, compression: HTTP.compression,
                      require_yaml_content_type: true, &block)
      text = request(:get, url, headers: headers, transfer: transfer, transport: transport,
                                compression: compression,
                                require_yaml_content_type: require_yaml_content_type)
      YAMLCamel.each_document(text, limits: limits, &block)
    end

    # Sends a value as YAML and returns the first document of the response, or nil when the response
    # carries no body.
    def post(url, object, **options) = send_body(:post, url, object, **options)

    def put(url, object, **options) = send_body(:put, url, object, **options)

    def patch(url, object, **options) = send_body(:patch, url, object, **options)

    # Sends a DELETE and returns the first document of the response, or nil when it carries no body.
    def delete(url, headers: {}, limits: Limits.default, transfer: IO::TransferLimits.default,
               transport: HTTP.transport, compression: HTTP.compression,
               require_yaml_content_type: true)
      text = request(:delete, url, headers: headers, transfer: transfer, transport: transport,
                                   compression: compression,
                                   require_yaml_content_type: require_yaml_content_type)
      text.empty? ? nil : YAMLCamel.load_stream(text, limits: limits).first
    end

    # Performs one request and returns the response body as YAML text, checked and decompressed.
    # This is the seam every call above goes through, and the one to reach for when a caller wants
    # text rather than parsed values.
    def request(method, url, headers: {}, body: nil, transfer: IO::TransferLimits.default,
                transport: HTTP.transport, compression: HTTP.compression,
                require_yaml_content_type: true)
      response = transport.request(method: method, url: url,
                                   headers: request_headers(headers, body, compression),
                                   body: body, max_bytes: transfer.max_body_bytes)
      body_text(response, transfer: transfer, compression: compression,
                          require_yaml_content_type: require_yaml_content_type)
    end

    # Checks a response and returns its body as YAML text. Separate from the transport so the rules
    # that matter can be tested without a network.
    def body_text(response, transfer: IO::TransferLimits.default, compression: HTTP.compression,
                  require_yaml_content_type: true)
      bytes = response.body.to_s
      if bytes.bytesize > transfer.max_body_bytes
        raise ResponseTooLargeError, "the response body is over the #{transfer.max_body_bytes} byte limit."
      end
      raise HTTPStatusError.new(response.status, bytes) unless response.success?

      decoded = decode_body(bytes, response["content-encoding"], transfer, compression)
      content_type = response["content-type"]
      # An empty body carries no YAML to misread, so its content type is not worth refusing over.
      if require_yaml_content_type && !decoded.empty? && !IO::MediaType.yaml?(content_type)
        raise UnexpectedContentTypeError,
              "the server answered with Content-Type #{content_type || "none"}, which is not YAML."
      end

      decoded
    end

    def decode_body(bytes, encoding, transfer, compression)
      encoding = encoding.to_s.split(",").last.to_s.strip.downcase
      case encoding
      when "", "identity"
        bytes
      when compression.content_encoding, "x-#{compression.content_encoding}"
        # The header is believed only as far as the bytes bear it out.
        return bytes unless compression.compressed?(bytes)

        inflated = compression.decompress(bytes, max_output_bytes: transfer.max_inflated_bytes)
        # max_output_bytes above lets a compliant codec refuse this while inflating, but a caller's
        # own codec is not this library's to trust, so the size is checked again here rather than
        # assuming an injected Compression policed its own bound.
        if inflated.bytesize > transfer.max_inflated_bytes
          raise InflatedTooLargeError, "the body inflates past the #{transfer.max_inflated_bytes} byte limit."
        end

        inflated
      else
        raise UnsupportedContentEncodingError,
              "the server answered with Content-Encoding #{encoding}, which is not handled."
      end
    end
    private_class_method :decode_body

    def send_body(method, url, object, headers: {}, compress_body: false, sort_keys: false,
                  emit_limits: EmitLimits.default, limits: Limits.default,
                  transfer: IO::TransferLimits.default, transport: HTTP.transport,
                  compression: HTTP.compression, require_yaml_content_type: true)
      text = YAMLCamel.dump(object, sort_keys: sort_keys, limits: emit_limits)
      body = compress_body ? compression.compress(text) : text
      sent = headers.to_h { |name, value| [name.to_s, value] }
      sent["Content-Type"] = IO::MediaType::CANONICAL
      sent["Content-Encoding"] = compression.content_encoding if compress_body

      answer = request(method, url, headers: sent, body: body, transfer: transfer,
                                    transport: transport, compression: compression,
                                    require_yaml_content_type: require_yaml_content_type)
      answer.empty? ? nil : YAMLCamel.load_stream(answer, limits: limits).first
    end
    private_class_method :send_body

    def request_headers(headers, body, compression)
      out = { "Accept" => IO::MediaType::CANONICAL,
              "Accept-Encoding" => compression.content_encoding }
      out["Content-Type"] = IO::MediaType::CANONICAL if body
      out.merge(headers.to_h { |name, value| [name.to_s, value] })
    end
    private_class_method :request_headers
  end
end
