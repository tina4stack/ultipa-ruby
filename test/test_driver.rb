#!/usr/bin/env ruby
# frozen_string_literal: true

# Live, no-mock tests for the Ultipa driver against a real gqldb server.
#
#     TINA4_TEST_ULTIPA_URL=ultipa://admin:C8e1234!@192.168.88.99:60071 ruby test/test_driver.rb
#
# Uses the existing `default` graph (the community edition caps graph count), with a
# dedicated `Tina4TestRuby` label it inserts and deletes, so it never mutates real
# data and never collides with the other language drivers.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "tina4_ultipa"

URL = ENV["TINA4_TEST_ULTIPA_URL"] || "ultipa://admin:C8e1234!@192.168.88.99:60071"
GRAPH = ENV["TINA4_TEST_ULTIPA_GRAPH"] || "default"
LABEL = "Tina4TestRuby"
VIZ_LABEL = "Tina4VizRuby" # NODE/EDGE decode tests use their own label
BLOB_LABEL = "Tina4BlobRuby" # BLOB roundtrip test uses its own label

def assert(cond, msg)
  raise "ASSERT FAILED: #{msg}" unless cond
end

def cleanup(db)
  db.execute("MATCH (n:#{LABEL}) DETACH DELETE n")
rescue Tina4Ultipa::Error
  # first run: nothing to delete
end

def cleanup_viz(db)
  db.execute("MATCH (n:#{VIZ_LABEL}) DETACH DELETE n")
rescue Tina4Ultipa::Error
  # first run: nothing to delete
end

def cleanup_blob(db)
  db.execute("MATCH (n:#{BLOB_LABEL}) DETACH DELETE n")
rescue Tina4Ultipa::Error
  # first run: nothing to delete
end

def test_scalar_roundtrip(db)
  r = db.query("RETURN 1 AS n, 'hi' AS s, 3.14 AS f, true AS b")
  assert(r.columns == %w[n s f b], "columns #{r.columns.inspect}")
  assert(r.rows[0] == [1, "hi", 3.14, true], "row #{r.rows[0].inspect}")
  puts "PASS scalar-roundtrip  (server #{db.server_version})"
end

def test_node_write_read(db)
  w = db.execute(
    "INSERT (:#{LABEL} {name: 'Alice', age: 30}), (:#{LABEL} {name: 'Bob', age: 25})",
  )
  assert(w.dml_stats[:inserted_nodes] == 2, "dml #{w.dml_stats.inspect}")
  r = db.query(
    "MATCH (n:#{LABEL}) WHERE n.name = $name RETURN n.name AS name, n.age AS age",
    params: { name: "Alice" },
  )
  assert(r.to_h_rows == [{ "name" => "Alice", "age" => 30 }], "dicts #{r.to_h_rows.inspect}")
  puts "PASS node-write-read   (INSERT 2 nodes, matched Alice/30 by param)"
end

def test_node_decode(db)
  db.execute(
    "INSERT (a:#{VIZ_LABEL} {name: 'Alice', age: 30}), (b:#{VIZ_LABEL} {name: 'Bob', age: 25})",
  )
  r = db.query("MATCH (n:#{VIZ_LABEL}) WHERE n.name = 'Alice' RETURN n")
  node = r.rows[0][0]
  assert(node.is_a?(Hash), "node is a Hash, got #{node.class}: #{node.inspect}")
  assert(node["_kind"] == "node", "node _kind #{node.inspect}")
  assert(node["labels"] == [VIZ_LABEL], "node labels #{node["labels"].inspect}")
  assert(!node["id"].to_s.empty?, "node id present #{node.inspect}")
  assert(node["properties"] == { "name" => "Alice", "age" => 30 },
         "node properties #{node["properties"].inspect}")
  puts "PASS node-decode      (#{node.inspect})"
end

def test_edge_decode(db)
  db.execute(
    "MATCH (a:#{VIZ_LABEL} {name: 'Alice'}), (b:#{VIZ_LABEL} {name: 'Bob'}) " \
    "INSERT (a)-[:KNOWS {since: 2020}]->(b)",
  )
  r = db.query("MATCH (:#{VIZ_LABEL})-[e:KNOWS]->(:#{VIZ_LABEL}) RETURN e")
  edge = r.rows[0][0]
  assert(edge.is_a?(Hash), "edge is a Hash, got #{edge.class}: #{edge.inspect}")
  assert(edge["_kind"] == "edge", "edge _kind #{edge.inspect}")
  assert(edge["type"] == "KNOWS", "edge type #{edge["type"].inspect}")
  assert(!edge["from"].to_s.empty?, "edge from present #{edge.inspect}")
  assert(!edge["to"].to_s.empty?, "edge to present #{edge.inspect}")
  assert(edge["properties"] == { "since" => 2020 },
         "edge properties #{edge["properties"].inspect}")
  puts "PASS edge-decode      (#{edge.inspect})"
end

def test_list_decode(db)
  # SHOW NODE LABELS returns a `label` column of PropertyType LIST; each cell is a
  # one-element list like ["Person"]. Exercises the LIST/SET codec path end to end.
  r = db.query("SHOW NODE LABELS")
  assert(r.columns.include?("label"), "columns include label #{r.columns.inspect}")
  row = r.to_h_rows[0]
  assert(!row.nil?, "at least one node label row")
  label = row["label"]
  assert(label.is_a?(Array), "label is an Array, got #{label.class}: #{label.inspect}")
  assert(label[0].is_a?(String) && !label[0].empty?,
         "label[0] is a non-empty String #{label.inspect}")
  puts "PASS list-decode      (label=#{label.inspect})"
end

def test_map_decode(db)
  # db.overview() returns a single cell of PropertyType MAP (enum 16), whose wire
  # format is byte-identical to a node/edge property block. Exercises the MAP codec
  # path end to end, including nested LISTs and MAPs decoded recursively.
  r = db.query("RETURN db.overview()")
  cell = r.scalar
  assert(cell.is_a?(Hash), "overview cell is a Hash, got #{cell.class}: #{cell.inspect}")

  label_counts = cell["labelCounts"]
  assert(label_counts.is_a?(Array), "labelCounts is an Array, got #{label_counts.class}: #{label_counts.inspect}")
  assert(!label_counts.empty?, "at least one labelCounts entry #{cell.inspect}")
  lc0 = label_counts[0]
  assert(lc0.is_a?(Hash) && lc0.key?("label") && lc0.key?("count") && lc0.key?("type"),
         "labelCounts entry has label/count/type #{lc0.inspect}")

  known = label_counts.find { |e| %w[Person Company].include?(e["label"]) }
  assert(!known.nil?, "a known label (Person/Company) present in #{label_counts.map { |e| e["label"] }.inspect}")
  assert(known["count"].is_a?(Numeric), "known label count is numeric #{known.inspect}")

  edge_patterns = cell["edgePatterns"]
  assert(edge_patterns.is_a?(Array), "edgePatterns is an Array, got #{edge_patterns.class}: #{edge_patterns.inspect}")
  unless edge_patterns.empty?
    ep0 = edge_patterns[0]
    assert(ep0.is_a?(Hash) && ep0.key?("fromLabel") && ep0.key?("edgeLabel") &&
           ep0.key?("toLabel") && ep0.key?("edgeCount"),
           "edgePatterns entry has fromLabel/edgeLabel/toLabel/edgeCount #{ep0.inspect}")
  end

  puts "PASS map-decode       (#{label_counts.length} labelCounts, #{edge_patterns.length} edgePatterns; " \
       "#{known["label"]}=#{known["count"]})"
end

def test_datetime_decode(db)
  # SHOW USERS returns a `created_at` column of PropertyType DATETIME/TIMESTAMP
  # (enum 8/9), an 8-byte little-endian uint64 unix time. Exercises the datetime
  # codec path end to end: the cell must decode to an ISO-8601 string, not raw bytes.
  r = db.query("SHOW USERS")
  assert(r.columns.include?("created_at"), "columns include created_at #{r.columns.inspect}")
  row = r.to_h_rows[0]
  assert(!row.nil?, "at least one user row")
  created_at = row["created_at"]
  assert(created_at.is_a?(String), "created_at is a String, got #{created_at.class}: #{created_at.inspect}")
  assert(created_at =~ /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/,
         "created_at matches ISO-8601 'YYYY-MM-DD HH:MM:SS' #{created_at.inspect}")
  puts "PASS datetime-decode  (created_at=#{created_at.inspect})"
end

def test_date_decimal_decode(db)
  # RETURN date(...) yields a PropertyType DATE cell (enum 21): 4 bytes of
  # uint16-LE year, uint8 month, uint8 day. cast(... AS decimal) yields a
  # DECIMAL cell (enum 13): a UTF-8 string returned verbatim to keep precision.
  r = db.query("RETURN date('2026-08-21') AS d, cast(3.14 AS decimal) AS m")
  row = r.rows[0]
  d = row[0]
  m = row[1]
  assert(d == "2026-08-21", "date decodes to 'YYYY-MM-DD', got #{d.class}: #{d.inspect}")
  assert(m.is_a?(String), "decimal stays a String, got #{m.class}: #{m.inspect}")
  assert(m == "3.14", "decimal preserves precision as '3.14', got #{m.inspect}")
  puts "PASS date-decimal     (d=#{d.inspect}, m=#{m.inspect})"
end

def test_all_types_decode(db)
  # temporal / spatial / interval / vector - the full authoritative type set.
  r = db.query(
    "RETURN time('10:30:00') AS t, zoned_datetime('2026-08-21T10:30:00+02:00') AS zdt, " \
    "point({x: 1.5, y: 2.5}) AS p, vector([1.0, 2.0, 3.0]) AS v, " \
    "duration('P1Y2M') AS ym, duration('PT1H30M') AS ds",
  )
  row = r.to_h_rows[0]
  assert(row["t"] == "10:30:00", "time #{row["t"].inspect}")
  assert(row["zdt"] == "2026-08-21 10:30:00+02:00", "zoned_datetime #{row["zdt"].inspect}")
  assert(row["p"].is_a?(Hash) && row["p"]["x"] == 1.5 && row["p"]["y"] == 2.5 &&
         row["p"]["srid"] == 7203, "point #{row["p"].inspect}")
  assert(row["v"] == [1.0, 2.0, 3.0], "vector #{row["v"].inspect}")
  assert(row["ym"] == { "months" => 14 }, "year_to_month #{row["ym"].inspect}")
  assert(row["ds"] == { "seconds" => 5400, "nanoseconds" => 0 }, "day_to_second #{row["ds"].inspect}")
  puts "PASS all-types        (time/zoned-dt/point/vector/year-month/day-second)"
end

def test_path_decode(db)
  # A PropertyType PATH cell: nodeCount, (len + nodeData)..., edgeCount, (len + edgeData)...
  r = db.query("MATCH p = (n:Person)-[e:KNOWS]->(m) RETURN p LIMIT 1")
  p = r.rows[0] && r.rows[0][0]
  assert(!p.nil?, "at least one Person-KNOWS path present")
  assert(p.is_a?(Hash) && p["_kind"] == "path", "path _kind #{p.inspect}")
  assert(p["nodes"].length == 2 && p["edges"].length == 1,
         "path has 2 nodes + 1 edge, got #{p["nodes"].length}/#{p["edges"].length}")
  assert(p["nodes"][0]["_kind"] == "node" && p["edges"][0]["_kind"] == "edge",
         "path element kinds #{p.inspect}")
  assert(!p["nodes"][0]["uuid"].to_s.empty?, "node should carry the 8-byte internal-id trailer")
  puts "PASS path-decode      (#{p["nodes"].length} nodes, #{p["edges"].length} edge, uuid trailer present)"
end

def test_blob_image_roundtrip(db)
  # A real 1x1 PNG stored as a BLOB property and read back byte-for-byte. The binary
  # (ASCII-8BIT) param encodes as a BLOB TypedValue; the property decodes back to bytes.
  require "base64"
  png = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC",
  )
  db.execute("MATCH (n:#{BLOB_LABEL}) DETACH DELETE n")
  db.execute("INSERT (:#{BLOB_LABEL} {name: 'pic', photo: $img})", params: { img: png })
  got = db.query("MATCH (n:#{BLOB_LABEL}) RETURN n").rows[0][0]["properties"]["photo"]
  db.execute("MATCH (n:#{BLOB_LABEL}) DETACH DELETE n")
  assert(got.is_a?(String) && got.b == png.b, "BLOB roundtrip: bytes must match")
  puts "PASS blob-roundtrip   (stored+read a #{png.bytesize}-byte PNG intact)"
end

def test_write_fails_loud(db)
  begin
    db.execute("THIS IS NOT GQL")
    raise "a bad statement must raise, not return"
  rescue Tina4Ultipa::Error => e
    assert(!e.message.to_s.empty?, "error carries a message")
  end
  puts "PASS write-fails-loud"
end

def test_connect_timeout
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    Tina4Ultipa::Client.new(
      host: "10.255.255.1", port: 60_061, username: "admin", password: "x",
      connect_timeout: 2,
    ).connect
    raise "expected Tina4Ultipa::ConnectError"
  rescue Tina4Ultipa::ConnectError => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert(e.host == "10.255.255.1" && e.port == 60_061, "host/port #{e.host}:#{e.port}")
    assert(elapsed < 5, "timeout not honoured: #{format('%.2f', elapsed)}s")
    puts "PASS connect-timeout   (#{e.message}, elapsed #{format('%.2f', elapsed)}s)"
  end
end

db = Tina4Ultipa::Client.from_url(URL, connect_timeout: 8).connect
db.graph = GRAPH # data queries need a graph selected in RBAC mode
cleanup(db)
cleanup_viz(db)
cleanup_blob(db)
begin
  test_scalar_roundtrip(db)
  test_node_write_read(db)
  test_node_decode(db)
  test_edge_decode(db)
  test_list_decode(db)
  test_map_decode(db)
  test_datetime_decode(db)
  test_date_decimal_decode(db)
  test_all_types_decode(db)
  test_path_decode(db)
  test_blob_image_roundtrip(db)
  test_write_fails_loud(db)
ensure
  cleanup(db)
  cleanup_viz(db)
  cleanup_blob(db)
  db.close
end
test_connect_timeout
puts "\nALL DRIVER TESTS PASSED"
