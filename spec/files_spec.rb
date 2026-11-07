# frozen_string_literal: true

require "tmpdir"

RSpec.describe YAMLCamel::Files do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  def path(name) = ::File.join(@dir, name)

  # A storage that keeps everything in a Hash, which is all an implementation of the contract needs.
  def memory_storage
    Class.new do
      include YAMLCamel::IO::Storage

      def initialize = @files = {}

      def read(path, max_bytes: nil) = @files.fetch(path)

      def write(path, bytes) = (@files[path] = bytes.b).bytesize

      def each_chunk(path, chunk_size: 64 * 1024)
        @files.fetch(path).b.chars.each_slice(chunk_size) { |slice| yield slice.join }
      end

      def exist?(path) = @files.key?(path)
    end.new
  end

  describe "plain files" do
    it "writes and reads one document" do
      expect(described_class.dump(path("a.yaml"), { "a" => 1 })).to eq("a: 1\n".bytesize)
      expect(described_class.load(path("a.yaml"))).to eq({ "a" => 1 })
    end

    it "writes and reads a stream of documents" do
      described_class.dump_stream(path("a.yaml"), [{ "a" => 1 }, [2]])
      expect(described_class.load_stream(path("a.yaml"))).to eq([{ "a" => 1 }, [2]])
    end

    it "yields one document at a time" do
      described_class.dump_stream(path("a.yaml"), [1, 2, 3])
      seen = []
      expect(described_class.each_document(path("a.yaml")) { |document| seen << document }).to eq(3)
      expect(seen).to eq([1, 2, 3])
    end

    it "reads the same values whatever the chunk size" do
      described_class.dump_stream(path("a.yaml"), [{ "a" => 1 }, { "b" => 2 }])
      [1, 5, 64, 65_536].each do |size|
        seen = []
        described_class.each_document(path("a.yaml"), chunk_size: size) { |doc| seen << doc }
        expect(seen).to eq([{ "a" => 1 }, { "b" => 2 }]), "chunk size #{size}"
      end
    end

    it "reads an empty file as no documents" do
      ::File.binwrite(path("empty.yaml"), "")
      expect(described_class.load_stream(path("empty.yaml"))).to eq([])
      expect(described_class.load(path("empty.yaml"))).to be_nil
    end

    it "lets the storage's own failure through" do
      expect { described_class.load(path("missing.yaml")) }.to raise_error(Errno::ENOENT)
    end

    it "reads through the module level helpers" do
      YAMLCamel.dump_file(path("a.yaml"), { "a" => 1 })
      expect(YAMLCamel.load_file(path("a.yaml"))).to eq({ "a" => 1 })
    end
  end

  describe "compressed files" do
    it "writes and reads a compressed document" do
      described_class.dump(path("a.yaml.gz"), { "a" => 1 }, compress: true)
      expect(::File.binread(path("a.yaml.gz"))[0, 2].b).to eq("\x1F\x8B".b)
      expect(described_class.load(path("a.yaml.gz"))).to eq({ "a" => 1 })
    end

    it "reads a compressed file a chunk at a time" do
      described_class.dump_stream(path("a.yaml.gz"), [{ "a" => 1 }, { "b" => 2 }], compress: true)
      seen = []
      described_class.each_document(path("a.yaml.gz"), chunk_size: 4) { |document| seen << document }
      expect(seen).to eq([{ "a" => 1 }, { "b" => 2 }])
    end

    it "reads a compressed file when told to rather than sniffing" do
      described_class.dump(path("a.yaml.gz"), { "a" => 1 }, compress: true)
      expect(described_class.load(path("a.yaml.gz"), compressed: true)).to eq({ "a" => 1 })
    end

    it "leaves a plain file alone when sniffing" do
      described_class.dump(path("a.yaml"), { "a" => 1 })
      expect(described_class.load(path("a.yaml"), compressed: :auto)).to eq({ "a" => 1 })
    end

    it "refuses a body that inflates past the bound" do
      compression = YAMLCamel::IO::GzipCompression.new
      ::File.binwrite(path("bomb.gz"), compression.compress("a: #{"x" * 2_000_000}"))
      transfer = YAMLCamel::IO::TransferLimits.new(max_inflated_bytes: 1_000)
      expect { described_class.load(path("bomb.gz"), transfer: transfer) }
        .to raise_error(YAMLCamel::InflatedTooLargeError)
    end

    it "reports a file that is not the compressed body it claims to be" do
      ::File.binwrite(path("broken.gz"), "\x1F\x8Bnot really gzip at all")
      expect { described_class.load(path("broken.gz")) }.to raise_error(YAMLCamel::CompressionError)
    end
  end

  describe "a storage of the caller's own" do
    it "reads and writes through it" do
      storage = memory_storage
      described_class.dump("anywhere", { "a" => 1 }, storage: storage)
      expect(storage.exist?("anywhere")).to be(true)
      expect(described_class.load("anywhere", storage: storage)).to eq({ "a" => 1 })
    end

    it "reads a compressed body through it" do
      storage = memory_storage
      described_class.dump("anywhere", { "a" => 1 }, compress: true, storage: storage)
      expect(described_class.load("anywhere", storage: storage)).to eq({ "a" => 1 })
    end

    it "can be set as the default for every call" do
      storage = memory_storage
      described_class.storage = storage
      described_class.dump("anywhere", { "a" => 1 })
      expect(described_class.load("anywhere")).to eq({ "a" => 1 })
    ensure
      described_class.storage = nil
    end

    it "reports a storage that does not meet the contract" do
      incomplete = Class.new { include YAMLCamel::IO::Storage }.new
      expect { described_class.load("anywhere", storage: incomplete) }.to raise_error(NotImplementedError)
    end
  end

  describe "a compression of the caller's own" do
    it "writes and reads through it" do
      codec = Class.new do
        include YAMLCamel::IO::Compression

        def content_encoding = "rot13"

        def compressed?(bytes) = bytes.to_s.start_with?("ROT13")

        def compress(bytes, level: nil) = "ROT13#{bytes.tr("a-z", "n-za-m")}"

        def decompressor(max_output_bytes: nil)
          Class.new do
            def initialize = @seen = +""

            def push(bytes) = (@seen << bytes) && ""

            def finish = @seen.sub("ROT13", "").tr("n-za-m", "a-z")
          end.new
        end
      end.new

      YAMLCamel::Files.dump("rot.yaml", { "a" => "hello" }, compress: true,
                                        storage: (storage = memory_storage), compression: codec)
      expect(YAMLCamel::Files.load("rot.yaml", compressed: true, storage: storage, compression: codec))
        .to eq({ "a" => "hello" })
    end

    it "raises the inflate error, not the parse-limit error, when the codec does not police its own bound" do
      # Real gzip framing, but a decompressor that ignores max_output_bytes, the same risk
      # HTTP.decode_body guards against by not trusting an injected Compression to police itself.
      codec = Class.new do
        include YAMLCamel::IO::Compression

        def content_encoding = "gzip"

        def compressed?(bytes) = YAMLCamel::IO::GzipCompression.new.compressed?(bytes)

        def compress(bytes, level: nil) = YAMLCamel::IO::GzipCompression.new.compress(bytes, level: level)

        def decompressor(max_output_bytes: nil)
          inflate = Zlib::Inflate.new(15 + 32)
          Class.new do
            define_method(:push) { |bytes| inflate.inflate(bytes.b) }
            define_method(:finish) do
              out = inflate.finish
              inflate.close
              out
            end
          end.new
        end
      end.new

      ::File.binwrite(path("bomb.gz"), codec.compress("a: #{"x" * 20_000_000}\n"))
      transfer = YAMLCamel::IO::TransferLimits.new(max_inflated_bytes: 1_000)
      expect { described_class.load(path("bomb.gz"), transfer: transfer, compression: codec) }
        .to raise_error(YAMLCamel::InflatedTooLargeError)
    end
  end
end
