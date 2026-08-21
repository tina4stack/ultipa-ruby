# frozen_string_literal: true

# Thin gRPC client for the Ultipa `ultipa-gqldb` server.
#
# Auth: SessionService.Login(username, password[, default_graph]) -> session_id,
# then that id rides every call as the gRPC metadata header `session-id`.
# Query: QueryService.Gql(GqlRequest) -> GqlResponse. This is the whole surface the
# Tina4 graph adapter needs; node/edge/traverse are built in GQL on top of query.

require "uri"
require "grpc"

# The generated stubs `require 'gqldb_pb'` / `require 'gqldb_services_pb'` by bare
# name, so put their directory on the load path before requiring them.
_gen_dir = File.expand_path("gen", __dir__)
$LOAD_PATH.unshift(_gen_dir) unless $LOAD_PATH.include?(_gen_dir)
require "gqldb_pb"
require "gqldb_services_pb"

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
      @dml_stats = if d
                     { inserted_nodes: d.inserted_nodes, inserted_edges: d.inserted_edges,
                       deleted_nodes: d.deleted_nodes, deleted_edges: d.deleted_edges,
                       set_nodes: d.set_nodes, set_edges: d.set_edges }
                   else
                     { inserted_nodes: 0, inserted_edges: 0, deleted_nodes: 0,
                       deleted_edges: 0, set_nodes: 0, set_edges: 0 }
                   end
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
      @session = nil
      @query = nil
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

      target = "#{@host}:#{@port}"
      creds = @use_tls ? GRPC::Core::ChannelCredentials.new : :this_channel_is_insecure
      @channel = GRPC::Core::Channel.new(target, nil, creds)
      started = monotonic
      wait_for_ready(@channel, started)

      @session = Gqldb::SessionService::Stub.new(target, creds, channel_override: @channel)
      @query = Gqldb::QueryService::Stub.new(target, creds, channel_override: @channel)
      begin
        resp = @session.login(
          Gqldb::LoginRequest.new(
            username: @username || "", password: @password || "", default_graph: @graph,
          ),
          deadline: Time.now + @connect_timeout,
        )
      rescue GRPC::BadStatus => e
        close
        raise wrap(e, "login failed")
      end
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
        resp = @query.gql(req, metadata: { "session-id" => @session_id.to_s })
      rescue GRPC::BadStatus => e
        raise wrap(e, "gql failed")
      end
      Result.new(resp)
    end

    # Run a writing GQL statement (read_only = false).
    def execute(gql, params: nil, graph: nil, timeout: nil)
      query(gql, params: params, graph: graph, read_only: false, timeout: timeout)
    end

    def close
      @channel.close if @channel.respond_to?(:close)
    rescue StandardError
      # best effort - the channel is being torn down regardless
    ensure
      @channel = @session = @query = @session_id = nil
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wait_for_ready(channel, started)
      states = GRPC::Core::ConnectivityStates
      deadline = Time.now + @connect_timeout
      state = channel.connectivity_state(true)
      until state == states::READY
        break if Time.now >= deadline

        channel.watch_connectivity_state(state, deadline)
        state = channel.connectivity_state(true)
      end
      return if state == states::READY

      elapsed = monotonic - started
      close
      raise ConnectError.new(@host, @port, elapsed)
    end

    def wrap(rpc_error, prefix)
      detail = rpc_error.respond_to?(:details) ? rpc_error.details : nil
      detail = rpc_error.message if detail.nil? || detail.to_s.empty?
      code = rpc_error.class.name.to_s.split("::").last
      Error.new("#{prefix}: #{detail}", code: code, cause: rpc_error)
    end
  end
end
