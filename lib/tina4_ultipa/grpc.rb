# frozen_string_literal: true

require "socket"
require "openssl"
require "http/2"

# Minimal gRPC-over-HTTP/2 client for this driver's 2 unary RPCs.
#
# We ride the pure-Ruby `http-2` gem (no C extensions, no google-protobuf
# transitive dep) and wrap it in the gRPC framing convention:
#
#     +--------+------------+---------+
#     | 0x00   | u32 BE len | payload |    (compressed flag = 0 = uncompressed)
#     +--------+------------+---------+
#
# The response comes back the same way, with the RPC outcome in HTTP/2
# trailers as `grpc-status: N` and optionally `grpc-message: text`.
#
# Only unary_unary is supported - streaming RPCs (server/client/bidi) are not
# used by gqldb's Login/Gql surface. Adding them is a self-contained extension.

module Tina4Ultipa
  module GrpcClient
    # Raised by Channel#unary when the peer returns a non-OK grpc-status trailer.
    class RpcError < StandardError
      attr_reader :status_code, :status_name

      GRPC_STATUS_NAMES = {
        0 => "OK", 1 => "CANCELLED", 2 => "UNKNOWN", 3 => "INVALID_ARGUMENT",
        4 => "DEADLINE_EXCEEDED", 5 => "NOT_FOUND", 6 => "ALREADY_EXISTS",
        7 => "PERMISSION_DENIED", 8 => "RESOURCE_EXHAUSTED", 9 => "FAILED_PRECONDITION",
        10 => "ABORTED", 11 => "OUT_OF_RANGE", 12 => "UNIMPLEMENTED",
        13 => "INTERNAL", 14 => "UNAVAILABLE", 15 => "DATA_LOSS",
        16 => "UNAUTHENTICATED",
      }.freeze

      def initialize(status_code, message)
        @status_code = status_code
        @status_name = GRPC_STATUS_NAMES[status_code] || "STATUS_#{status_code}"
        super("gRPC #{@status_name}: #{message}")
      end
    end

    # Raised when the socket connect / TLS handshake times out. Callers translate
    # this into their own ConnectError with the elapsed time.
    class ConnectTimeout < StandardError; end

    # A single HTTP/2 connection to a gqldb host. Not thread-safe; use one
    # Channel per Client instance.
    class Channel
      READ_CHUNK = 16_384

      def initialize(host, port, use_tls: false, connect_timeout: 10.0)
        @host = host
        @port = port.to_i
        @use_tls = use_tls
        @connect_timeout = connect_timeout.to_f
        @socket = nil
        @client = nil
        @closed = false
      end

      def connect
        return self if @socket

        deadline = monotonic + @connect_timeout

        # Plain TCP connect with a wall-clock deadline. Socket.tcp handles
        # IPv4/IPv6 fallback; a bare TCPSocket does not.
        begin
          @socket = Socket.tcp(@host, @port, connect_timeout: @connect_timeout)
        rescue Errno::ETIMEDOUT, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
               Errno::ENETUNREACH, SocketError => e
          raise ConnectTimeout, "tcp: #{e.class}: #{e.message}"
        end

        if @use_tls
          ctx = OpenSSL::SSL::SSLContext.new
          ctx.alpn_protocols = ["h2"]
          @socket = OpenSSL::SSL::SSLSocket.new(@socket, ctx)
          @socket.sync_close = true
          @socket.hostname = @host
          begin
            @socket.connect
          rescue OpenSSL::SSL::SSLError => e
            raise ConnectTimeout, "tls: #{e.message}"
          end
          if @socket.respond_to?(:alpn_protocol) && @socket.alpn_protocol != "h2"
            raise ConnectTimeout, "alpn: server did not select h2"
          end
        end

        # http-2's Client emits :frame events with encoded HTTP/2 frames.
        # Write them straight to the socket. All inbound bytes get fed back
        # via `client << data`, which raises the state-machine events on
        # the stream we open. The client preface + initial SETTINGS fires
        # automatically the first time we emit a frame in `unary`, so there
        # is nothing to do here beyond having a live socket + a Client
        # instance ready to receive callbacks.
        @client = HTTP2::Client.new
        @client.on(:frame) { |bytes| @socket.write(bytes) }
        self
      end

      # unary(method, payload_bytes, metadata:, timeout:) -> response payload bytes
      #
      # Raises RpcError on non-OK grpc-status, ConnectTimeout on connect/read
      # deadline overrun.
      def unary(method, payload, metadata: {}, timeout: nil)
        connect
        deadline = timeout ? monotonic + timeout.to_f : nil

        headers = {
          ":method" => "POST",
          ":scheme" => @use_tls ? "https" : "http",
          ":path" => method,
          ":authority" => "#{@host}:#{@port}",
          "content-type" => "application/grpc+proto",
          "te" => "trailers",
          "user-agent" => "tina4-ultipa-ruby/0.2 http-2",
        }
        metadata.each { |k, v| headers[k.to_s.downcase] = v.to_s }

        stream = @client.new_stream

        resp_status = nil
        resp_message = nil
        resp_body = "".b
        stream_closed = false
        rst_reason = nil

        stream.on(:headers) do |h|
          h.each do |k, v|
            case k
            when "grpc-status"  then resp_status = v.to_i
            when "grpc-message" then resp_message = v
            end
          end
        end
        stream.on(:data) { |d| resp_body << d.b }
        stream.on(:close) { stream_closed = true }
        stream.on(:reset) { |code| rst_reason = code; stream_closed = true }

        stream.headers(headers, end_stream: false)
        stream.data(frame_encode(payload), end_stream: true)

        drain_until(deadline) { stream_closed }

        if rst_reason
          raise RpcError.new(2, "stream reset (#{rst_reason})")
        end
        # No grpc-status trailer at all is a protocol violation (or the server
        # closed the connection); surface as UNKNOWN so the caller sees why.
        if resp_status.nil?
          raise RpcError.new(2, "no grpc-status trailer (server may have closed)")
        end
        unless resp_status.zero?
          raise RpcError.new(resp_status, resp_message || "")
        end

        frame_decode(resp_body)
      end

      def close
        return if @closed

        @closed = true
        @socket&.close rescue nil
        @socket = nil
        @client = nil
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Drive the read side until the block returns true or the deadline elapses.
      def drain_until(deadline)
        loop do
          return if yield

          remaining = deadline ? deadline - monotonic : nil
          raise ConnectTimeout, "read deadline" if remaining && remaining <= 0

          ready = IO.select([@socket], nil, nil, remaining)
          raise ConnectTimeout, "read deadline" if ready.nil?

          chunk = read_available
          break if chunk.nil? || chunk.empty?

          @client << chunk
        end
      end

      def read_available
        # SSLSocket buffers ciphertext internally; readpartial returns whatever
        # plaintext is available. On plain TCP, readpartial blocks until any
        # byte arrives (we already selected, so at least one is ready).
        @socket.readpartial(READ_CHUNK)
      rescue EOFError
        nil
      end

      # gRPC frame = 1 byte flag (0 = uncompressed) + u32 BE length + payload.
      def frame_encode(payload)
        "\x00".b + [payload.bytesize].pack("N") + payload.b
      end

      # Decode ONE gRPC frame. Unary responses ship exactly one frame; if the
      # server ever streams multiple frames back, extend this to loop.
      def frame_decode(bytes)
        raise RpcError.new(2, "short gRPC frame (#{bytes.bytesize} bytes)") if bytes.bytesize < 5

        _flag = bytes.getbyte(0)
        len = bytes.byteslice(1, 4).unpack1("N")
        if bytes.bytesize < 5 + len
          raise RpcError.new(2, "truncated gRPC frame (want #{5 + len}, got #{bytes.bytesize})")
        end

        bytes.byteslice(5, len).b
      end
    end
  end
end
