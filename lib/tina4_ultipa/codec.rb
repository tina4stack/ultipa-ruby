# frozen_string_literal: true

require "json"

# Encode/decode gqldb TypedValue <-> Ruby values.
#
# Grounded against the official gqldb-nodejs SDK decoder and verified live against
# gqldb-grpc 6.2.130 CE. All multi-byte integers are little-endian. Mirrors the
# Python reference `_codec.py`, which passes all live tests.
#
# Inside composites (node/edge/map/list/table props) each value is a
# **TypedValueEntry**: `type:u8 · isNull:u8 · dataLen:u32 · data` - a 1-byte type
# plus a 1-byte is-null (NOT a u16 type); a set is-null yields nil regardless of data.

module Tina4Ultipa
  module Codec
    module_function

    # PropertyType (as the enum symbol google-protobuf hands back) -> pack/unpack
    # directive for the fixed-width little-endian numeric types.
    NUMERIC = {
      PROPERTY_TYPE_INT32:  "l<",
      PROPERTY_TYPE_UINT32: "L<",
      PROPERTY_TYPE_INT64:  "q<",
      PROPERTY_TYPE_UINT64: "Q<",
      PROPERTY_TYPE_FLOAT:  "e",
      PROPERTY_TYPE_DOUBLE: "E",
    }.freeze

    STRINGY = %i[PROPERTY_TYPE_STRING PROPERTY_TYPE_TEXT].freeze
    NULLISH = %i[PROPERTY_TYPE_NULL PROPERTY_TYPE_UNSET].freeze
    LISTY = %i[PROPERTY_TYPE_LIST PROPERTY_TYPE_SET].freeze
    MAPPY = %i[PROPERTY_TYPE_MAP PROPERTY_TYPE_RECORD].freeze
    LOCAL_DT = %i[PROPERTY_TYPE_DATETIME PROPERTY_TYPE_LOCAL_DATETIME].freeze

    # A google-protobuf enum field usually reads back as a Symbol, but falls back
    # to the raw Integer for values it does not know. Normalise to the symbol.
    INT_TO_SYM = {
      0 => :PROPERTY_TYPE_UNSET, 1 => :PROPERTY_TYPE_INT32, 2 => :PROPERTY_TYPE_UINT32,
      3 => :PROPERTY_TYPE_INT64, 4 => :PROPERTY_TYPE_UINT64, 5 => :PROPERTY_TYPE_FLOAT,
      6 => :PROPERTY_TYPE_DOUBLE, 7 => :PROPERTY_TYPE_STRING,
      8 => :PROPERTY_TYPE_DATETIME, 9 => :PROPERTY_TYPE_TIMESTAMP, 10 => :PROPERTY_TYPE_TEXT,
      11 => :PROPERTY_TYPE_BLOB, 12 => :PROPERTY_TYPE_POINT, 13 => :PROPERTY_TYPE_DECIMAL,
      14 => :PROPERTY_TYPE_LIST, 15 => :PROPERTY_TYPE_SET, 16 => :PROPERTY_TYPE_MAP,
      17 => :PROPERTY_TYPE_NULL, 18 => :PROPERTY_TYPE_BOOL,
      19 => :PROPERTY_TYPE_LOCAL_DATETIME, 20 => :PROPERTY_TYPE_ZONED_DATETIME,
      21 => :PROPERTY_TYPE_DATE, 22 => :PROPERTY_TYPE_ZONED_TIME,
      23 => :PROPERTY_TYPE_LOCAL_TIME, 24 => :PROPERTY_TYPE_YEAR_TO_MONTH,
      25 => :PROPERTY_TYPE_DAY_TO_SECOND, 26 => :PROPERTY_TYPE_RECORD,
      27 => :PROPERTY_TYPE_POINT3D, 28 => :PROPERTY_TYPE_VECTOR,
      29 => :PROPERTY_TYPE_TABLE, 30 => :PROPERTY_TYPE_PATH, 31 => :PROPERTY_TYPE_ERROR,
      32 => :PROPERTY_TYPE_NODE, 33 => :PROPERTY_TYPE_EDGE
    }.freeze

    # ── temporal / spatial helpers ──────────────────────────────────────

    def date(data)
      return nil if data.nil? || data.bytesize < 4

      y = data.byteslice(0, 2).unpack1("s<") # signed year (BCE round-trips)
      format("%04d-%02d-%02d", y, data.getbyte(2), data.getbyte(3))
    end

    def time_str(hour, minute, sec, nanos)
      base = format("%02d:%02d:%02d", hour, minute, sec)
      return base if nanos.nil? || nanos.zero?

      base + format(".%09d", nanos).sub(/0+\z/, "").sub(/\.\z/, "")
    end

    def local_time(data)
      return nil if data.nil? || data.bytesize < 8

      nanos = data.unpack1("@4 L<")
      time_str(data.getbyte(0), data.getbyte(1), data.getbyte(2), nanos)
    end

    def zoned_time(data)
      return nil if data.nil? || data.bytesize < 10

      nanos = data.unpack1("@4 L<")
      off = data.unpack1("@8 s<")
      time_str(data.getbyte(0), data.getbyte(1), data.getbyte(2), nanos) + offset(off)
    end

    def offset(minutes)
      sign = minutes >= 0 ? "+" : "-"
      m = minutes.abs
      format("%s%02d:%02d", sign, m / 60, m % 60)
    end

    def datetime_frac(base, nanos)
      return base if nanos.nil? || nanos.zero?

      base + format(".%09d", nanos).sub(/0+\z/, "").sub(/\.\z/, "")
    end

    def local_datetime(data)
      if !data.nil? && data.bytesize >= 11
        y = data.unpack1("s<")
        nanos = data.unpack1("@7 L<")
        base = format("%04d-%02d-%02d %02d:%02d:%02d", y, data.getbyte(2), data.getbyte(3),
                      data.getbyte(4), data.getbyte(5), data.getbyte(6))
        return datetime_frac(base, nanos)
      end
      unix(data) # legacy 8-byte unix fallback
    end

    def zoned_datetime(data)
      if !data.nil? && data.bytesize >= 13
        y = data.unpack1("s<")
        nanos = data.unpack1("@7 L<")
        off = data.unpack1("@11 s<")
        base = format("%04d-%02d-%02d %02d:%02d:%02d", y, data.getbyte(2), data.getbyte(3),
                      data.getbyte(4), data.getbyte(5), data.getbyte(6))
        return datetime_frac(base, nanos) + offset(off)
      end
      unix(data)
    end

    def timestamp(data)
      if !data.nil? && data.bytesize >= 12
        secs = data.unpack1("q<")
        nanos = data.unpack1("@8 L<")
        begin
          base = Time.at(secs).utc.strftime("%Y-%m-%d %H:%M:%S")
          return datetime_frac(base, nanos)
        rescue StandardError, RangeError
          return secs
        end
      end
      unix(data)
    end

    # Legacy 8-byte unix time (seconds/ms/us) -> 'YYYY-MM-DD HH:MM:SS' (UTC).
    def unix(data)
      return nil if data.nil? || data.bytesize < 8

      v = data.byteslice(0, 8).unpack1("Q<")
      secs = v > 1e14 ? v / 1e6 : (v > 1e11 ? v / 1e3 : v)
      begin
        Time.at(secs).utc.strftime("%Y-%m-%d %H:%M:%S")
      rescue StandardError, RangeError
        v
      end
    end

    def point(data)
      return nil if data.nil? || data.bytesize < 16

      x = data.unpack1("E")
      y = data.unpack1("@8 E")
      srid = data.bytesize >= 20 ? data.unpack1("@16 L<") : 7203
      { "_kind" => "point", "x" => x, "y" => y, "srid" => srid }
    end

    def point3d(data)
      return nil if data.nil? || data.bytesize < 24

      x = data.unpack1("E")
      y = data.unpack1("@8 E")
      z = data.unpack1("@16 E")
      srid = data.bytesize >= 28 ? data.unpack1("@24 L<") : 9757
      { "_kind" => "point3d", "x" => x, "y" => y, "z" => z, "srid" => srid }
    end

    def vector(data)
      return [] if data.nil? || data.bytesize < 4

      dim = data.unpack1("L<")
      return [] if data.bytesize < 4 + dim * 4

      Array.new(dim) { |i| data.unpack1("@#{4 + i * 4} e") }
    end

    def year_to_month(data)
      return { "months" => 0 } if data.nil? || data.bytesize < 4

      { "months" => data.unpack1("l<") }
    end

    def day_to_second(data)
      return { "seconds" => 0, "nanoseconds" => 0 } if data.nil? || data.bytesize < 12

      { "seconds" => data.unpack1("q<"), "nanoseconds" => data.unpack1("@8 L<") }
    end

    def error(data)
      s = (data || "".b).dup.force_encoding("UTF-8")
      obj = JSON.parse(s)
      { "_kind" => "error", "code" => (obj["code"] || 0), "message" => (obj["message"] || "") }
    rescue StandardError
      { "_kind" => "error", "code" => 0, "message" => s }
    end

    # Walks a self-describing binary blob, reading little-endian fixed-width ints,
    # length-prefixed strings, and TypedValueEntry composites. Mirrors Python _Reader.
    class Reader
      attr_accessor :d, :p

      def initialize(data)
        @d = (data || "".b).dup.force_encoding("BINARY")
        @p = 0
      end

      def u8
        v = @d.getbyte(@p)
        @p += 1
        v
      end

      def u16
        v = @d.byteslice(@p, 2).unpack1("S<")
        @p += 2
        v
      end

      def u32
        v = @d.byteslice(@p, 4).unpack1("L<")
        @p += 4
        v
      end

      def u64
        v = @d.byteslice(@p, 8).unpack1("Q<")
        @p += 8
        v
      end

      # uint16 length prefix + that many UTF-8 bytes.
      def str
        n = u16
        v = @d.byteslice(@p, n).dup.force_encoding("UTF-8")
        @p += n
        v
      end

      # A TypedValueEntry: type u8, isNull u8, len u32, data -> decoded value (nil if null).
      def tve
        t = u8
        is_null = u8
        n = u32
        data = @d.byteslice(@p, n)
        @p += n
        is_null.zero? ? Codec.scalar(t, data) : nil
      end

      # uint16 count of (uint16 keyLen + key + TypedValueEntry) property pairs.
      def props
        out = {}
        u16.times do
          key = str
          out[key] = tve
        end
        out
      end
    end

    # ── composites ──────────────────────────────────────────────────────

    def list(data)
      r = Reader.new(data)
      Array.new(r.u16) { r.tve }
    end

    def table(data)
      r = Reader.new(data)
      cols = Array.new(r.u16) { r.str }
      rows = Array.new(r.u16) { Array.new(r.u16) { r.tve } }
      { "_kind" => "table", "columns" => cols, "rows" => rows }
    end

    # Optional 8-byte little-endian uint64 internal-id trailer (gqldb 6.1.147+).
    def trailer(reader)
      reader.p + 8 <= reader.d.bytesize ? reader.u64.to_s : ""
    end

    def node(data)
      r = Reader.new(data)
      nid = r.str
      labels = Array.new(r.u16) { r.str }
      props = r.props
      { "_kind" => "node", "id" => nid, "labels" => labels, "properties" => props,
        "uuid" => trailer(r) }
    end

    def edge(data)
      r = Reader.new(data)
      eid = r.str
      etype = r.str
      src = r.str
      dst = r.str
      props = r.props
      { "_kind" => "edge", "id" => eid, "type" => etype, "from" => src, "to" => dst,
        "properties" => props, "uuid" => trailer(r) }
    end

    def path(data)
      r = Reader.new(data)
      nodes = Array.new(r.u16) do
        n = r.u32
        v = node(r.d.byteslice(r.p, n))
        r.p += n
        v
      end
      edges = Array.new(r.u16) do
        n = r.u32
        v = edge(r.d.byteslice(r.p, n))
        r.p += n
        v
      end
      { "_kind" => "path", "nodes" => nodes, "edges" => edges }
    end

    # ── dispatch ────────────────────────────────────────────────────────

    # Decode a raw property/value payload of a given PropertyType. Used both for the
    # top-level TypedValue and for each value inside a composite.
    def scalar(ptype, data)
      t = ptype
      t = INT_TO_SYM[t] || t if t.is_a?(Integer)
      return nil if NULLISH.include?(t)

      fmt = NUMERIC[t]
      unless fmt.nil?
        return nil if data.nil? || data.empty?

        return data.unpack1(fmt)
      end
      return data.dup.force_encoding("UTF-8") if STRINGY.include?(t)
      return !(data.nil? || data.empty? || data.getbyte(0).zero?) if t == :PROPERTY_TYPE_BOOL
      # BLOB: raw bytes as a binary string.
      return (data || "".b).dup.force_encoding("BINARY") if t == :PROPERTY_TYPE_BLOB
      # DECIMAL is a precision-preserving UTF-8 string: return it verbatim, never to_f.
      return data.dup.force_encoding("UTF-8") if t == :PROPERTY_TYPE_DECIMAL
      return date(data) if t == :PROPERTY_TYPE_DATE
      return local_datetime(data) if LOCAL_DT.include?(t)
      return zoned_datetime(data) if t == :PROPERTY_TYPE_ZONED_DATETIME
      return timestamp(data) if t == :PROPERTY_TYPE_TIMESTAMP
      return local_time(data) if t == :PROPERTY_TYPE_LOCAL_TIME
      return zoned_time(data) if t == :PROPERTY_TYPE_ZONED_TIME
      return year_to_month(data) if t == :PROPERTY_TYPE_YEAR_TO_MONTH
      return day_to_second(data) if t == :PROPERTY_TYPE_DAY_TO_SECOND
      return point(data) if t == :PROPERTY_TYPE_POINT
      return point3d(data) if t == :PROPERTY_TYPE_POINT3D
      return vector(data) if t == :PROPERTY_TYPE_VECTOR
      return list(data) if LISTY.include?(t)
      return Reader.new(data).props if MAPPY.include?(t)
      return table(data) if t == :PROPERTY_TYPE_TABLE
      return node(data) if t == :PROPERTY_TYPE_NODE
      return edge(data) if t == :PROPERTY_TYPE_EDGE
      return path(data) if t == :PROPERTY_TYPE_PATH
      return error(data) if t == :PROPERTY_TYPE_ERROR

      # Unmapped/future types: hand back the raw bytes rather than lose or guess.
      data
    end

    # gqldb.TypedValue -> a Ruby value (nil for null; Hash for node/edge/...).
    def decode(tv)
      return nil if tv.is_null

      scalar(tv.type, tv.data)
    end

    # A Ruby value -> gqldb.TypedValue, for query parameters.
    def encode(value)
      case value
      when nil
        Gqldb::TypedValue.new(type: :PROPERTY_TYPE_NULL, is_null: true)
      when true, false
        Gqldb::TypedValue.new(type: :PROPERTY_TYPE_BOOL, data: (value ? "\x01" : "\x00").b)
      when Integer
        Gqldb::TypedValue.new(type: :PROPERTY_TYPE_INT64, data: [value].pack("q<"))
      when Float
        Gqldb::TypedValue.new(type: :PROPERTY_TYPE_DOUBLE, data: [value].pack("E"))
      when String
        # A binary (ASCII-8BIT) String is the Ruby analogue of Python `bytes`:
        # send it as a BLOB so raw bytes round-trip intact. UTF-8/other -> STRING.
        if value.encoding == Encoding::ASCII_8BIT
          Gqldb::TypedValue.new(type: :PROPERTY_TYPE_BLOB, data: value)
        else
          Gqldb::TypedValue.new(type: :PROPERTY_TYPE_STRING, data: value.b)
        end
      else
        # Anything else -> UTF-8 bytes.
        Gqldb::TypedValue.new(type: :PROPERTY_TYPE_STRING, data: value.to_s.b)
      end
    end
  end
end
