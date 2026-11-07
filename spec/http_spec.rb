# frozen_string_literal: true

require "support/test_server"

RSpec.describe YAMLCamel::HTTP do
  let(:yaml_headers) { { "Content-Type" => "application/yaml" } }

  # A transport that answers from a script, which is all an implementation of the contract needs.
  def stub_transport(status: 200, headers: nil, body: "a: 1\n", &block)
    answered = headers || yaml_headers
    Class.new do
      include YAMLCamel::IO::Transport

      define_method(:initialize) do
        @status = status
        @headers = answered
        @body = body
        @block = block
        @calls = []
      end

      attr_reader :calls

      define_method(:request) do |method:, url:, headers: {}, body: nil, max_bytes: nil|
        @calls << { method: method, url: url, headers: headers, body: body, max_bytes: max_bytes }
        next @block.call(method, url, headers, body) if @block

        YAMLCamel::IO::Response.new(status: @status, headers: @headers, body: @body)
      end
    end.new
  end

  describe "reading a response" do
    it "parses a YAML body" do
      transport = stub_transport(body: "a: 1\nb: [2]\n")
      expect(described_class.get("http://example.test/x", transport: transport))
        .to eq({ "a" => 1, "b" => [2] })
    end

    it "returns every document of a stream" do
      transport = stub_transport(body: "--- 1\n--- 2\n")
      expect(described_class.get_stream("http://example.test/x", transport: transport)).to eq([1, 2])
    end

    it "yields one document at a time" do
      transport = stub_transport(body: "--- 1\n--- 2\n")
      seen = []
      count = described_class.each_document("http://example.test/x", transport: transport) do |document|
        seen << document
      end
      expect([count, seen]).to eq([2, [1, 2]])
    end

    it "asks for YAML and offers to take it compressed" do
      transport = stub_transport
      described_class.get("http://example.test/x", transport: transport)
      headers = transport.calls.first[:headers]
      expect(headers["Accept"]).to eq("application/yaml")
      expect(headers["Accept-Encoding"]).to eq("gzip")
    end

    it "passes the byte bound to the transport rather than checking it afterwards" do
      transport = stub_transport
      transfer = YAMLCamel::IO::TransferLimits.new(max_body_bytes: 4_096)
      described_class.get("http://example.test/x", transport: transport, transfer: transfer)
      expect(transport.calls.first[:max_bytes]).to eq(4_096)
    end

    it "refuses a body larger than the bound even from a transport that ignored it" do
      transport = stub_transport(body: "a: #{"x" * 5_000}\n")
      transfer = YAMLCamel::IO::TransferLimits.new(max_body_bytes: 100)
      expect { described_class.get("http://example.test/x", transport: transport, transfer: transfer) }
        .to raise_error(YAMLCamel::ResponseTooLargeError)
    end

    it "reports a status outside the successful range" do
      transport = stub_transport(status: 404, body: "gone")
      expect { described_class.get("http://example.test/x", transport: transport) }
        .to raise_error(YAMLCamel::HTTPStatusError) { |error| expect(error.status).to eq(404) }
    end

    it "reports a body that does not claim to be YAML" do
      transport = stub_transport(headers: { "Content-Type" => "text/html" })
      expect { described_class.get("http://example.test/x", transport: transport) }
        .to raise_error(YAMLCamel::UnexpectedContentTypeError)
    end

    it "takes any body when the content type check is turned off" do
      transport = stub_transport(headers: { "Content-Type" => "text/html" })
      expect(described_class.get("http://example.test/x", transport: transport,
                                                          require_yaml_content_type: false))
        .to eq({ "a" => 1 })
    end

    it "takes the older YAML content types" do
      ["text/yaml", "application/x-yaml", "text/x-yaml", "application/yaml; charset=utf-8"].each do |type|
        transport = stub_transport(headers: { "Content-Type" => type })
        expect(described_class.get("http://example.test/x", transport: transport)).to eq({ "a" => 1 })
      end
    end

    it "reads a header whatever case the server sent it in" do
      transport = stub_transport(headers: { "CONTENT-TYPE" => "application/yaml" })
      expect(described_class.get("http://example.test/x", transport: transport)).to eq({ "a" => 1 })
    end

    it "reports an encoding it does not handle" do
      transport = stub_transport(headers: yaml_headers.merge("Content-Encoding" => "br"))
      expect { described_class.get("http://example.test/x", transport: transport) }
        .to raise_error(YAMLCamel::UnsupportedContentEncodingError)
    end
  end

  describe "compressed responses" do
    let(:compression) { YAMLCamel::IO::GzipCompression.new }

    it "inflates a body the server compressed" do
      transport = stub_transport(headers: yaml_headers.merge("Content-Encoding" => "gzip"),
                                 body: YAMLCamel::IO::GzipCompression.new.compress("a: 1\n"))
      expect(described_class.get("http://example.test/x", transport: transport)).to eq({ "a" => 1 })
    end

    it "believes the bytes over the header when the two disagree" do
      # A client library that already inflated the body leaves the header behind it.
      transport = stub_transport(headers: yaml_headers.merge("Content-Encoding" => "gzip"),
                                 body: "a: 1\n")
      expect(described_class.get("http://example.test/x", transport: transport)).to eq({ "a" => 1 })
    end

    it "refuses a body that inflates past the bound" do
      transport = stub_transport(headers: yaml_headers.merge("Content-Encoding" => "gzip"),
                                 body: YAMLCamel::IO::GzipCompression.new.compress("a: #{"x" * 2_000_000}"))
      transfer = YAMLCamel::IO::TransferLimits.new(max_inflated_bytes: 1_000)
      expect { described_class.get("http://example.test/x", transport: transport, transfer: transfer) }
        .to raise_error(YAMLCamel::InflatedTooLargeError)
    end

    it "refuses a body a compression of the caller's own ignored the bound for" do
      # max_output_bytes is passed to an injected Compression, but it is not this library's to
      # trust with it: one that answers whatever it wants regardless is still caught here.
      reckless = Class.new do
        include YAMLCamel::IO::Compression

        def content_encoding = "gzip"

        def compressed?(_bytes) = true

        def decompress(_bytes, max_output_bytes: nil) = "a: #{"x" * 2_000}\n"
      end.new
      transport = stub_transport(headers: yaml_headers.merge("Content-Encoding" => "gzip"), body: "irrelevant")
      transfer = YAMLCamel::IO::TransferLimits.new(max_inflated_bytes: 100)
      expect {
        described_class.get("http://example.test/x", transport: transport, transfer: transfer,
                                                     compression: reckless)
      }.to raise_error(YAMLCamel::InflatedTooLargeError)
    end
  end

  describe "sending a body" do
    it "posts YAML and reads the answer" do
      transport = stub_transport(body: "ok: true\n")
      expect(described_class.post("http://example.test/x", { "a" => 1 }, transport: transport))
        .to eq({ "ok" => true })
      call = transport.calls.first
      expect(call[:method]).to eq(:post)
      expect(call[:body]).to eq("a: 1\n")
      expect(call[:headers]["Content-Type"]).to eq("application/yaml")
    end

    it "compresses the body when asked to" do
      transport = stub_transport
      described_class.post("http://example.test/x", { "a" => 1 }, compress_body: true,
                                                                  transport: transport)
      call = transport.calls.first
      expect(call[:headers]["Content-Encoding"]).to eq("gzip")
      expect(YAMLCamel::IO::GzipCompression.new.decompress(call[:body])).to eq("a: 1\n")
    end

    it "returns nil for an answer with no body" do
      transport = stub_transport(status: 204, body: "")
      expect(described_class.post("http://example.test/x", { "a" => 1 }, transport: transport)).to be_nil
    end

    it "sends the other methods the same way" do
      transport = stub_transport
      described_class.put("http://example.test/x", { "a" => 1 }, transport: transport)
      described_class.patch("http://example.test/x", { "a" => 1 }, transport: transport)
      described_class.delete("http://example.test/x", transport: transport)
      expect(transport.calls.map { |call| call[:method] }).to eq(%i[put patch delete])
    end

    it "can be set as the default transport for every call" do
      transport = stub_transport
      described_class.transport = transport
      expect(described_class.get("http://example.test/x")).to eq({ "a" => 1 })
    ensure
      described_class.transport = nil
    end

    it "reports a transport that does not meet the contract" do
      incomplete = Class.new { include YAMLCamel::IO::Transport }.new
      expect { described_class.get("http://example.test/x", transport: incomplete) }
        .to raise_error(NotImplementedError)
    end
  end

  describe "over a socket" do
    let(:body) { "name: camel\nlegs: 4\n" }

    around do |example|
      @server = YAMLCamelSpec::TestServer.new do |request|
        case request.path
        when "/plain" then [200, { "Content-Type" => "application/yaml" }, body]
        when "/gzip"
          [200, { "Content-Type" => "application/yaml", "Content-Encoding" => "gzip" },
           YAMLCamel::IO::GzipCompression.new.compress(body)]
        when "/big" then [200, { "Content-Type" => "application/yaml" }, "a: #{"x" * 200_000}\n"]
        when "/html" then [200, { "Content-Type" => "text/html" }, "<p>no</p>"]
        when "/boom" then [500, { "Content-Type" => "application/yaml" }, "error: true\n"]
        when "/echo"
          headers = { "Content-Type" => "application/yaml" }
          headers["Content-Encoding"] = request.headers["content-encoding"] if request.headers["content-encoding"]
          [200, headers, request.body.to_s]
        else [404, { "Content-Type" => "text/plain" }, "missing"]
        end
      end
      example.run
    ensure
      @server.stop
    end

    it "fetches YAML from a real socket" do
      expect(described_class.get(@server.url("/plain"))).to eq({ "name" => "camel", "legs" => 4 })
    end

    it "fetches a compressed body from a real socket" do
      expect(described_class.get(@server.url("/gzip"))).to eq({ "name" => "camel", "legs" => 4 })
    end

    it "posts a body a server reads back" do
      answer = described_class.post(@server.url("/echo"), { "sent" => [1, 2] })
      expect(answer).to eq({ "sent" => [1, 2] })
      expect(@server.requests.last.headers["content-type"]).to eq("application/yaml")
    end

    it "posts a compressed body" do
      expect(described_class.post(@server.url("/echo"), { "sent" => 1 }, compress_body: true)).to eq({ "sent" => 1 })
      expect(@server.requests.last.headers["content-encoding"]).to eq("gzip")
    end

    it "refuses a body larger than the bound while it is arriving" do
      transfer = YAMLCamel::IO::TransferLimits.new(max_body_bytes: 1_000)
      expect { described_class.get(@server.url("/big"), transfer: transfer) }
        .to raise_error(YAMLCamel::ResponseTooLargeError)
    end

    it "reports a failing status" do
      expect { described_class.get(@server.url("/boom")) }.to raise_error(YAMLCamel::HTTPStatusError)
    end

    it "reports a body that is not YAML" do
      expect { described_class.get(@server.url("/html")) }
        .to raise_error(YAMLCamel::UnexpectedContentTypeError)
    end

    it "reports a server it cannot reach at all" do
      expect { described_class.get("http://127.0.0.1:1/nothing") }
        .to raise_error(YAMLCamel::TransportError)
    end
  end
end
