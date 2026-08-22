# frozen_string_literal: true

# Hand-rolled proto3 wire codec for the gqldb messages this driver uses.
#
# The `grpc` gem calls MessageClass.encode(msg) and MessageClass.decode(bytes)
# on whatever class we register with the stub. We supply those two class
# methods so grpc has no idea protobuf isn't in the loop. No google-protobuf
# runtime, no descriptor pool, no generated stubs.
#
# What we speak:
#   Envelopes:  LoginRequest / LoginResponse / GqlRequest / GqlResponse
#   Nested:     Parameter / TypedValue / Row / DmlStats
#   Enum:       PropertyType (integer constants + symbol lookup for codec parity)
#
# Proto3 rules we honour:
#   * default scalar values are NOT written to the wire
#   * unknown fields on read are skipped (server may add fields; we ignore them)
#   * repeated scalar strings/bytes/messages are NOT packed (one tag per element)
#   * repeated numeric scalars would be packed - this schema has none
#
# NOT implemented (gqldb.proto does not use them; adding any is a self-contained
# ~15-line extension):
#   oneof, map<>, Any, packed scalars, groups, edition-2023 features.

module Gqldb
  # PropertyType. Integer constants + symbol<->int lookups. Codec speaks symbols,
  # wire speaks integers.
  module PropertyType
    NAMES = {
       0 => :PROPERTY_TYPE_UNSET,
       1 => :PROPERTY_TYPE_INT32,
       2 => :PROPERTY_TYPE_UINT32,
       3 => :PROPERTY_TYPE_INT64,
       4 => :PROPERTY_TYPE_UINT64,
       5 => :PROPERTY_TYPE_FLOAT,
       6 => :PROPERTY_TYPE_DOUBLE,
       7 => :PROPERTY_TYPE_STRING,
       8 => :PROPERTY_TYPE_DATETIME,
       9 => :PROPERTY_TYPE_TIMESTAMP,
      10 => :PROPERTY_TYPE_TEXT,
      11 => :PROPERTY_TYPE_BLOB,
      12 => :PROPERTY_TYPE_POINT,
      13 => :PROPERTY_TYPE_DECIMAL,
      14 => :PROPERTY_TYPE_LIST,
      15 => :PROPERTY_TYPE_SET,
      16 => :PROPERTY_TYPE_MAP,
      17 => :PROPERTY_TYPE_NULL,
      18 => :PROPERTY_TYPE_BOOL,
      19 => :PROPERTY_TYPE_LOCAL_DATETIME,
      20 => :PROPERTY_TYPE_ZONED_DATETIME,
      21 => :PROPERTY_TYPE_DATE,
      22 => :PROPERTY_TYPE_ZONED_TIME,
      23 => :PROPERTY_TYPE_LOCAL_TIME,
      24 => :PROPERTY_TYPE_YEAR_TO_MONTH,
      25 => :PROPERTY_TYPE_DAY_TO_SECOND,
      26 => :PROPERTY_TYPE_RECORD,
      27 => :PROPERTY_TYPE_POINT3D,
      28 => :PROPERTY_TYPE_VECTOR,
      29 => :PROPERTY_TYPE_TABLE,
      30 => :PROPERTY_TYPE_PATH,
      31 => :PROPERTY_TYPE_ERROR,
      32 => :PROPERTY_TYPE_NODE,
      33 => :PROPERTY_TYPE_EDGE,
    }.freeze
    IDS = NAMES.invert.freeze

    def self.id_of(sym_or_int)
      return sym_or_int if sym_or_int.is_a?(Integer)
      IDS[sym_or_int] || 0
    end

    def self.name_of(int_or_sym)
      return int_or_sym if int_or_sym.is_a?(Symbol)
      NAMES[int_or_sym] || int_or_sym
    end
  end

  # ---- wire encoders --------------------------------------------------------
  module Wire
    module_function

    def varint(buf, n)
      # Handle negative numbers as two's-complement uint64.
      n = (1 << 64) + n if n.negative?
      while n >= 0x80
        buf << ((n & 0x7F) | 0x80)
        n >>= 7
      end
      buf << (n & 0x7F)
    end

    def tag(buf, field_no, wire_type)
      varint(buf, (field_no << 3) | wire_type)
    end

    def write_bytes(buf, field_no, bytes)
      return if bytes.nil? || bytes.empty?
      tag(buf, field_no, 2)
      varint(buf, bytes.bytesize)
      buf << bytes.b
    end

    def write_string(buf, field_no, str)
      return if str.nil? || str.empty?
      write_bytes(buf, field_no, str.dup.force_encoding("BINARY"))
    end

    def write_varint(buf, field_no, n)
      return if n.zero?
      tag(buf, field_no, 0)
      varint(buf, n)
    end

    def write_bool(buf, field_no, b)
      return unless b
      tag(buf, field_no, 0)
      varint(buf, 1)
    end
  end

  # ---- wire reader ----------------------------------------------------------
  class Reader
    def initialize(bytes)
      @b = bytes.dup.force_encoding("BINARY")
      @p = 0
      @end = @b.bytesize
    end

    def eof?
      @p >= @end
    end

    def read_varint
      r = 0
      sh = 0
      loop do
        byte = @b.getbyte(@p)
        @p += 1
        r |= (byte & 0x7F) << sh
        return r if (byte & 0x80).zero?
        sh += 7
      end
    end

    def read_signed_varint
      v = read_varint
      v -= (1 << 64) if v >= (1 << 63)
      v
    end

    def read_len
      n = read_varint
      s = @b.byteslice(@p, n) || ""
      @p += n
      s.dup.force_encoding("BINARY")
    end

    def read_string
      read_len.force_encoding("UTF-8")
    end

    def skip(wire_type)
      case wire_type
      when 0 then read_varint
      when 2 then @p += read_varint
      when 5 then @p += 4
      when 1 then @p += 8
      else raise ArgumentError, "unknown wire type #{wire_type}"
      end
    end
  end

  # ---- messages -------------------------------------------------------------

  class TypedValue
    attr_accessor :type, :data, :is_null

    def initialize(type: 0, data: "".b, is_null: false)
      @type = PropertyType.id_of(type)
      @data = (data || "".b).dup.force_encoding("BINARY")
      @is_null = is_null
    end

    def self.encode(msg)
      buf = "".b
      Wire.write_varint(buf, 1, msg.type)
      Wire.write_bytes(buf, 2, msg.data)
      Wire.write_bool(buf, 3, msg.is_null)
      buf
    end

    def self.decode(bytes)
      o = new
      r = Reader.new(bytes)
      until r.eof?
        tag = r.read_varint
        fn = tag >> 3
        wt = tag & 7
        if    fn == 1 && wt == 0 then o.type = r.read_varint
        elsif fn == 2 && wt == 2 then o.data = r.read_len
        elsif fn == 3 && wt == 0 then o.is_null = !r.read_varint.zero?
        else r.skip(wt)
        end
      end
      o
    end
  end

  class Parameter
    attr_accessor :name, :value

    def initialize(name: "", value: TypedValue.new)
      @name = name.to_s
      @value = value
    end

    def self.encode(msg)
      buf = "".b
      Wire.write_string(buf, 1, msg.name)
      inner = TypedValue.encode(msg.value)
      Wire.write_bytes(buf, 2, inner)
      buf
    end
  end

  class Row
    attr_accessor :values

    def initialize(values: [])
      @values = values
    end

    def self.decode(bytes)
      o = new
      r = Reader.new(bytes)
      until r.eof?
        tag = r.read_varint
        fn = tag >> 3
        wt = tag & 7
        if fn == 1 && wt == 2
          o.values << TypedValue.decode(r.read_len)
        else
          r.skip(wt)
        end
      end
      o
    end
  end

  class DmlStats
    attr_accessor :inserted_nodes, :inserted_edges, :deleted_nodes,
                  :deleted_edges, :set_nodes, :set_edges

    def initialize(inserted_nodes: 0, inserted_edges: 0, deleted_nodes: 0,
                   deleted_edges: 0, set_nodes: 0, set_edges: 0)
      @inserted_nodes = inserted_nodes
      @inserted_edges = inserted_edges
      @deleted_nodes = deleted_nodes
      @deleted_edges = deleted_edges
      @set_nodes = set_nodes
      @set_edges = set_edges
    end

    def self.decode(bytes)
      o = new
      r = Reader.new(bytes)
      until r.eof?
        tag = r.read_varint
        fn = tag >> 3
        wt = tag & 7
        (r.skip(wt); next) if wt != 0
        v = r.read_signed_varint
        case fn
        when 1 then o.inserted_nodes = v
        when 2 then o.inserted_edges = v
        when 3 then o.deleted_nodes = v
        when 4 then o.deleted_edges = v
        when 5 then o.set_nodes = v
        when 6 then o.set_edges = v
        end
      end
      o
    end
  end

  class LoginRequest
    attr_accessor :username, :password, :default_graph

    def initialize(username: "", password: "", default_graph: "")
      @username = username
      @password = password
      @default_graph = default_graph
    end

    def self.encode(msg)
      buf = "".b
      Wire.write_string(buf, 1, msg.username)
      Wire.write_string(buf, 2, msg.password)
      Wire.write_string(buf, 3, msg.default_graph)
      buf
    end
  end

  class LoginResponse
    attr_accessor :session_id, :server_version, :roles, :is_cluster,
                  :cluster_id, :partition_count, :capabilities,
                  :current_graph, :time_cost_ns, :disk_cost_ns, :compute_cost_ns

    def initialize
      @session_id = 0
      @server_version = ""
      @roles = []
      @is_cluster = false
      @cluster_id = ""
      @partition_count = 0
      @capabilities = []
      @current_graph = ""
      @time_cost_ns = 0
      @disk_cost_ns = 0
      @compute_cost_ns = 0
    end

    def self.decode(bytes)
      o = new
      r = Reader.new(bytes)
      until r.eof?
        tag = r.read_varint
        fn = tag >> 3
        wt = tag & 7
        case [fn, wt]
        when [1, 0]  then o.session_id = r.read_varint
        when [2, 2]  then o.server_version = r.read_string
        when [3, 2]  then o.roles << r.read_string
        when [10, 0] then o.is_cluster = !r.read_varint.zero?
        when [11, 2] then o.cluster_id = r.read_string
        when [12, 0] then o.partition_count = r.read_signed_varint
        when [20, 2] then o.capabilities << r.read_string
        when [21, 2] then o.current_graph = r.read_string
        when [22, 0] then o.time_cost_ns = r.read_signed_varint
        when [23, 0] then o.disk_cost_ns = r.read_signed_varint
        when [24, 0] then o.compute_cost_ns = r.read_signed_varint
        else r.skip(wt)
        end
      end
      o
    end
  end

  class GqlRequest
    attr_accessor :gql, :graph_name, :parameters, :session_id,
                  :transaction_id, :timeout, :read_only, :max_path_results

    def initialize(gql: "", graph_name: "", parameters: [], session_id: 0,
                   transaction_id: 0, timeout: 0, read_only: false,
                   max_path_results: 0)
      @gql = gql
      @graph_name = graph_name
      @parameters = parameters
      @session_id = session_id
      @transaction_id = transaction_id
      @timeout = timeout
      @read_only = read_only
      @max_path_results = max_path_results
    end

    def self.encode(msg)
      buf = "".b
      Wire.write_string(buf, 1, msg.gql)
      Wire.write_string(buf, 2, msg.graph_name)
      msg.parameters.each do |p|
        Wire.write_bytes(buf, 3, Parameter.encode(p))
      end
      Wire.write_varint(buf, 4, msg.session_id)
      Wire.write_varint(buf, 5, msg.transaction_id)
      Wire.write_varint(buf, 6, msg.timeout)
      Wire.write_bool(buf, 7, msg.read_only)
      Wire.write_varint(buf, 8, msg.max_path_results)
      buf
    end
  end

  class GqlResponse
    attr_accessor :columns, :rows, :row_count, :has_more, :warnings,
                  :rows_affected, :current_graph, :time_cost_ns,
                  :disk_cost_ns, :compute_cost_ns, :dml_stats

    def initialize
      @columns = []
      @rows = []
      @row_count = 0
      @has_more = false
      @warnings = []
      @rows_affected = 0
      @current_graph = ""
      @time_cost_ns = 0
      @disk_cost_ns = 0
      @compute_cost_ns = 0
      @dml_stats = DmlStats.new
    end

    def self.decode(bytes)
      o = new
      r = Reader.new(bytes)
      until r.eof?
        tag = r.read_varint
        fn = tag >> 3
        wt = tag & 7
        case [fn, wt]
        when [1, 2]  then o.columns << r.read_string
        when [2, 2]  then o.rows << Row.decode(r.read_len)
        when [3, 0]  then o.row_count = r.read_signed_varint
        when [4, 0]  then o.has_more = !r.read_varint.zero?
        when [5, 2]  then o.warnings << r.read_string
        when [6, 0]  then o.rows_affected = r.read_signed_varint
        when [7, 2]  then o.current_graph = r.read_string
        when [8, 0]  then o.time_cost_ns = r.read_signed_varint
        when [9, 0]  then o.disk_cost_ns = r.read_signed_varint
        when [10, 0] then o.compute_cost_ns = r.read_signed_varint
        when [11, 2] then o.dml_stats = DmlStats.decode(r.read_len)
        else r.skip(wt)
        end
      end
      o
    end
  end
end
