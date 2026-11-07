# frozen_string_literal: true

module YAMLCamel
  module IO
    # The contract for reading and writing YAML somewhere durable.
    #
    # The default reads and writes local files. Anything that answers these four methods can stand in
    # its place: an asset bundle, an object store, a virtual filesystem inside a game engine.
    #
    # A storage that cannot find what it was asked for raises, and the exception it raises is its own
    # (Errno::ENOENT from the file storage below) rather than a YAMLCamel error, since a caller
    # handling missing files is handling its own storage rather than YAML.
    module Storage
      # Reads the whole contents of a path as binary bytes. Raises InputTooLargeError when max_bytes
      # is given and the contents are larger, before the whole of it is in memory.
      def read(_path, max_bytes: nil)
        raise NotImplementedError, "#{self.class} does not implement #read"
      end

      # Writes bytes to a path, replacing whatever was there. Returns the number of bytes written.
      def write(_path, _bytes)
        raise NotImplementedError, "#{self.class} does not implement #write"
      end

      # Yields the contents in chunks of about chunk_size bytes, in order.
      def each_chunk(_path, chunk_size: 64 * 1024)
        raise NotImplementedError, "#{self.class} does not implement #each_chunk"
      end

      # True when a path holds something readable.
      def exist?(_path)
        raise NotImplementedError, "#{self.class} does not implement #exist?"
      end
    end

    # Storage over the local filesystem.
    class FileStorage
      include Storage

      def read(path, max_bytes: nil)
        return ::File.binread(path) if max_bytes.nil? || !max_bytes.is_a?(Integer)

        ::File.open(path, "rb") do |file|
          bytes = file.read(max_bytes + 1) || ""
          raise InputTooLargeError, "#{path} is over the #{max_bytes} byte limit." if bytes.bytesize > max_bytes

          bytes
        end
      end

      def write(path, bytes)
        ::File.binwrite(path, bytes)
      end

      def each_chunk(path, chunk_size: 64 * 1024)
        ::File.open(path, "rb") do |file|
          while (chunk = file.read(chunk_size))
            yield chunk
          end
        end
        nil
      end

      def exist?(path) = ::File.exist?(path)
    end
  end
end
