# frozen_string_literal: true

module YAMLCamel
  module IO
    # One HTTP answer, in the shape the YAML layer above needs and nothing more.
    class Response
      attr_reader :status, :headers, :body

      def initialize(status:, headers: {}, body: "")
        @status = Integer(status)
        @headers = headers.to_h { |name, value| [name.to_s.downcase, value] }
        @body = body.to_s
        freeze
      end

      # Reads a header without regard to case, which is how a server may send it.
      def [](name) = @headers[name.to_s.downcase]

      def success? = (200..299).cover?(@status)
    end

    # The contract for carrying a YAML body over HTTP.
    #
    # The default wraps Faraday. Anything that answers #request can stand in its place: an
    # application's own networking layer, connection pool, retries or offline cache implements this
    # and every call in YAMLCamel::HTTP goes through it.
    #
    # An implementation must honour max_bytes while the body is arriving, raising
    # ResponseTooLargeError as soon as the count is crossed rather than after the body is in memory.
    module Transport
      # Performs one request and returns a Response. Raises TransportError for a failure to reach the
      # server at all, which is separate from a server that answered with a status.
      def request(method:, url:, headers: {}, body: nil, max_bytes: nil)
        raise NotImplementedError, "#{self.class} does not implement #request"
      end
    end

    # Transport over Faraday, which wraps net/http and needs no C extension.
    #
    # Faraday is not a dependency of this gem: it is required the first time this transport is built,
    # so an application that supplies its own transport never has to have it installed.
    class FaradayTransport
      include Transport

      DEFAULT_OPEN_TIMEOUT = 10
      DEFAULT_TIMEOUT = 30

      def initialize(connection: nil, open_timeout: DEFAULT_OPEN_TIMEOUT, timeout: DEFAULT_TIMEOUT)
        unless connection
          begin
            require "faraday"
          rescue LoadError
            raise TransportError,
                  "the default HTTP transport needs the faraday gem. Add it, or pass a transport of " \
                  "your own to YAMLCamel::HTTP."
          end
        end
        @connection = connection
        @open_timeout = open_timeout
        @timeout = timeout
        @connection_mutex = Mutex.new
      end

      # Lazily builds the shared connection, guarded so two threads racing on the first request
      # cannot each build their own and split traffic across them.
      def connection
        @connection || @connection_mutex.synchronize do
          @connection ||= Faraday.new do |builder|
            builder.options.open_timeout = @open_timeout
            builder.options.timeout = @timeout
            builder.adapter Faraday.default_adapter
          end
        end
      end

      def request(method:, url:, headers: {}, body: nil, max_bytes: nil)
        received = +""
        response =
          begin
            connection.run_request(method.to_s.downcase.to_sym, url.to_s, body, headers) do |request|
              bound_body(request, received, max_bytes) if max_bytes
            end
          rescue ResponseTooLargeError
            raise
          rescue StandardError => e
            raise TransportError, "#{method.to_s.upcase} #{url} failed: #{e.class}: #{e.message}"
          end

        # An adapter that does not stream leaves the collected body empty and answers with the whole
        # of it, so the bound is checked again here for that path.
        payload = received.empty? ? response.body.to_s : received
        if max_bytes && payload.bytesize > max_bytes
          raise ResponseTooLargeError, "the response body is over the #{max_bytes} byte limit."
        end

        Response.new(status: response.status, headers: response.headers.to_h, body: payload)
      end

      private

      # Counts the body as it arrives and refuses it the moment it crosses the bound, so a server
      # that answers with gigabytes never gets to hand over more than the caller allowed.
      def bound_body(request, received, max_bytes)
        request.options.on_data = proc do |chunk, _received_bytes, _env|
          received << chunk
          next unless received.bytesize > max_bytes

          raise ResponseTooLargeError, "the response body is over the #{max_bytes} byte limit."
        end
      end
    end
  end
end
