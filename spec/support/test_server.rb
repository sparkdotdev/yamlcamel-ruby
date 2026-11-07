# frozen_string_literal: true

require "socket"

module YAMLCamelSpec
  # A one-connection-at-a-time HTTP server for the transport specs.
  #
  # Written over a plain TCP socket because the specs need a real request to cross a real socket, and
  # every web server worth using for that is a dependency this gem does not otherwise have.
  class TestServer
    Request = Struct.new(:method, :path, :headers, :body)

    attr_reader :requests

    # The block receives a Request and returns [status, headers, body].
    def initialize(&handler)
      @handler = handler
      @requests = []
      @server = TCPServer.new("127.0.0.1", 0)
      @running = true
      @thread = Thread.new { serve }
    end

    def port = @server.addr[1]

    def url(path = "/") = "http://127.0.0.1:#{port}#{path}"

    def stop
      @running = false
      @server.close unless @server.closed?
      @thread.join(2)
    end

    private

    def serve
      while @running
        begin
          socket = @server.accept
        rescue IOError, Errno::EBADF
          break
        end
        handle(socket)
      end
    end

    def handle(socket)
      request = read_request(socket)
      return socket.close if request.nil?

      @requests << request
      status, headers, body = @handler.call(request)
      body = body.to_s
      lines = ["HTTP/1.1 #{status} #{reason(status)}"]
      headers.each { |name, value| lines << "#{name}: #{value}" }
      lines << "Content-Length: #{body.bytesize}"
      lines << "Connection: close"
      socket.write("#{lines.join("\r\n")}\r\n\r\n")
      socket.write(body)
    rescue StandardError
      nil
    ensure
      socket.close unless socket.nil? || socket.closed?
    end

    def read_request(socket)
      line = socket.gets
      return nil if line.nil?

      method, path, = line.split(" ")
      headers = {}
      while (header = socket.gets) && header.strip != ""
        name, value = header.split(":", 2)
        headers[name.to_s.strip.downcase] = value.to_s.strip
      end
      length = headers["content-length"].to_i
      body = length.positive? ? socket.read(length) : nil
      Request.new(method, path, headers, body)
    end

    def reason(status)
      { 200 => "OK", 201 => "Created", 204 => "No Content", 400 => "Bad Request",
        404 => "Not Found", 500 => "Internal Server Error" }.fetch(status, "Status")
    end
  end
end
