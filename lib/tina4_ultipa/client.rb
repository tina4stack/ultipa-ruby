# frozen_string_literal: true

# Thin gRPC client for the Ultipa `ultipa-gqldb` server.
#
# Auth: SessionService.Login(username, password[, default_graph]) -> session_id,
# then that id rides every call as the gRPC metadata header `session-id`.
# Query: QueryService.Gql(GqlRequest) -> GqlResponse. This is the whole surface the
# Tina4 graph adapter needs; node/edge/traverse are built in GQL on top of query.
#
# Wire stack (pure Ruby, no C extensions, no google-protobuf):
#   * `http-2` gem drives HTTP/2 framing (HPACK, streams, flow control)
#   * lib/tina4_ultipa/grpc.rb wraps that in gRPC framing (unary_unary only)
#   * lib/tina4_ultipa/pb.rb hand-rolls proto3 for the 8 gqldb messages

require "uri"

require_relative "pb"
require_relative "grpc"
require_relative "codec"
require_relative "errors"

module Tina4Ultipa
  DEFAULT_PORT = 60_061

  # A gqldb result set - columns + rows, shaped like Tina4's DatabaseResult.
  class Result
    attr_reader :columns, :rows, :row_count, :rows_affected, :warnings,
                :current_graph, :dml_stats

    include Enumerable

    def initialize(resp)
      @columns = resp.columns.to_a
      @rows = resp.rows.map { |row| row.values.map { |v| Codec.decode(v) } }
      @row_count = resp.row_count
      @rows_affected = resp.rows_affected
      @warnings = resp.warnings.to_a
      @current_graph = resp.current_graph
      d = resp.dml_stats
      @dml_stats = { inserted_nodes: d.inserted_nodes, inserted_edges: d.inserted_edges,
                     deleted_nodes: d.deleted_nodes, deleted_edges: d.deleted_edges,
                     set_nodes: d.set_nodes, set_edges: d.set_edges }
    end

    # Rows as hashes keyed by column name.
    def to_h_rows
      @rows.map { |row| @columns.zip(row).to_h }
    end
    alias dicts to_h_rows

    # The first cell of the first row, or nil.
    def scalar
      first = @rows[0]
      first && !first.empty? ? first[0] : nil
    end

    def each(&block)
      to_h_rows.each(&block)
    end

    def length
      @rows.length
    end
    alias size length
  end

  class Client
    attr_reader :host, :port, :username, :graph, :connect_timeout, :use_tls,
                :server_version
    attr_writer :graph

    def initialize(host:, port: DEFAULT_PORT, username: nil, password: nil,
                   graph: nil, connect_timeout: 10, use_tls: false)
      @host = host
      @port = port.to_i
      @username = username
      @password = password
      @graph = graph || ""
      @connect_timeout = connect_timeout.to_f
      @use_tls = use_tls
      @channel = nil
      @session_id = nil
      @server_version = nil
    end

    # ultipa://user:pass@host:port/graph?connect_timeout=5&tls=1
    def self.from_url(url, **kw)
      u = URI.parse(url)
      q = URI.decode_www_form(u.query || "").to_h
      path_graph = (u.path || "").sub(%r{\A/}, "")
      new(
        host: u.host,
        port: (u.port || DEFAULT_PORT),
        username: (u.user || q["user"] || kw[:username]),
        password: (u.password || q["password"] || kw[:password]),
        graph: (path_graph.empty? ? kw[:graph] : path_graph),
        connect_timeout: (q["connect_timeout"] || kw[:connect_timeout] || 10).to_f,
        use_tls: (%w[1 true].include?(q["tls"]) || url.start_with?("ultipas://") ||
                  kw[:use_tls] || false),
      )
    end

    # -- connection ---------------------------------------------------------
    def connect
      return self unless @session_id.nil?

      @channel = GrpcClient::Channel.new(
        @host, @port, use_tls: @use_tls, connect_timeout: @connect_timeout,
      )
      started = monotonic
      begin
        @channel.connect
      rescue GrpcClient::ConnectTimeout => e
        elapsed = monotonic - started
        close
        raise ConnectError.new(@host, @port, elapsed, cause: e)
      end

      req = Gqldb::LoginRequest.new(
        username: @username || "", password: @password || "",
        default_graph: @graph,
      )
      begin
        resp_bytes = @channel.unary(
          "/gqldb.SessionService/Login",
          Gqldb::LoginRequest.encode(req),
          timeout: @connect_timeout,
        )
      rescue GrpcClient::RpcError => e
        close
        raise wrap(e, "login failed")
      rescue GrpcClient::ConnectTimeout => e
        elapsed = monotonic - started
        close
        raise ConnectError.new(@host, @port, elapsed, cause: e)
      end

      resp = Gqldb::LoginResponse.decode(resp_bytes)
      @session_id = resp.session_id
      @server_version = resp.server_version
      self
    end

    # -- queries ------------------------------------------------------------

    # Run a GQL statement and return a Result. Raises on error.
    def query(gql, params: nil, graph: nil, read_only: true, timeout: nil)
      connect
      req = Gqldb::GqlRequest.new(
        gql: gql,
        graph_name: graph.nil? ? @graph : graph,
        parameters: (params || {}).map do |k, v|
          Gqldb::Parameter.new(name: k.to_s, value: Codec.encode(v))
        end,
        session_id: @session_id || 0,
        read_only: read_only,
        timeout: timeout ? timeout.to_i : 0,
      )
      begin
        resp_bytes = @channel.unary(
          "/gqldb.QueryService/Gql",
          Gqldb::GqlRequest.encode(req),
          metadata: { "session-id" => @session_id.to_s },
          timeout: timeout ? timeout.to_f : nil,
        )
      rescue GrpcClient::RpcError => e
        raise wrap(e, "gql failed")
      end
      Result.new(Gqldb::GqlResponse.decode(resp_bytes))
    end

    # Run a writing GQL statement (read_only = false).
    def execute(gql, params: nil, graph: nil, timeout: nil)
      query(gql, params: params, graph: graph, read_only: false, timeout: timeout)
    end

    def close
      @channel&.close
    rescue StandardError
      # best effort - the channel is being torn down regardless
    ensure
      @channel = nil
      @session_id = nil
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wrap(rpc_error, prefix)
      code = rpc_error.respond_to?(:status_name) ? rpc_error.status_name : nil
      Error.new("#{prefix}: #{rpc_error.message}", code: code, cause: rpc_error)
    end
  end
end
