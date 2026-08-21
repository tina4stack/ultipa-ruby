<p align="center">
  <img src="https://tina4.com/logo.svg" alt="Tina4" height="88">
  &nbsp;&nbsp;<span>&times;</span>&nbsp;&nbsp;
  <img src="https://www.ultipa.com/assets/ultipa-logo.svg" alt="Ultipa" height="40">
</p>

<h1 align="center">tina4-ultipa</h1>
<h3 align="center">The Ultipa graph driver for Ruby</h3>

<p align="center">
  A full-fidelity gRPC client for the <a href="https://www.ultipa.com">Ultipa</a>
  graph database — every GQL type decoded, no Tina4 lock-in.
</p>

<p align="center">
  <a href="https://rubygems.org/gems/tina4-ultipa"><img src="https://img.shields.io/gem/v/tina4-ultipa?color=ed5034&label=gem" alt="RubyGems"></a>
  <img src="https://img.shields.io/badge/tests-live%20%C2%B7%20no%20mocks-2f9e44" alt="Tests">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT">
  <a href="https://www.ultipa.com"><img src="https://img.shields.io/badge/for-Ultipa%20gqldb-ed5034" alt="Ultipa"></a>
  <a href="https://tina4.com"><img src="https://img.shields.io/badge/part%20of-Tina4-ed5034" alt="Tina4"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#type-support">Type Support</a> &bull;
  <a href="https://www.ultipa.com/docs">Ultipa Docs</a> &bull;
  <a href="PROTOCOL.md">Protocol</a> &bull;
  <a href="https://tina4.com">tina4.com</a>
</p>

---

A thin, standalone **gRPC driver for the [Ultipa](https://www.ultipa.com) graph
database** (`ultipa-gqldb`). It is the Ultipa driver behind
[Tina4](https://tina4.com)'s graph data layer — but has **no Tina4 dependency** and
is perfectly usable on its own. Tina4's core stays zero-dependency; this driver is
an *optional* gem loaded only for `ultipa://` connections, speaking gRPC directly
(`grpc` + `google-protobuf`).

> **Ultipa** is a high-performance graph database with a GQL (ISO/IEC 39075) query
> surface. Learn more at **[ultipa.com](https://www.ultipa.com)** · docs at
> **[ultipa.com/docs](https://www.ultipa.com/docs)**.

## Why this driver

- **Complete value decoding.** Every gqldb `PropertyType` is decoded to a natural
  Ruby value — including the composites and temporals most thin clients skip
  (see [Type support](#type-support)).
- **Real gRPC, vendored stubs.** Generated protobuf stubs ship inside the gem
  (`lib/tina4_ultipa/gen/`), so there is no reflection round-trip and no codegen
  step at install time.
- **Fails loud.** A bad statement raises; it never returns a falsy value you might
  miss. An unreachable host raises within your `connect_timeout`.
- **Cross-language parity.** The same driver exists for
  [Python](https://github.com/tina4stack/ultipa-python),
  [Node.js](https://github.com/tina4stack/ultipa-node),
  [Ruby](https://github.com/tina4stack/ultipa-ruby) and
  [PHP](https://github.com/tina4stack/ultipa-php), decoding byte-for-byte identically.

## Install

```bash
gem install tina4-ultipa
```

or in a `Gemfile`:

```ruby
gem "tina4-ultipa"
```

## Quick start

```ruby
require "tina4_ultipa"

# from a URL...
db = Tina4Ultipa::Client.from_url("ultipa://admin:password@localhost:60061/mygraph").connect
# ...or explicitly
db = Tina4Ultipa::Client.new(
  host: "localhost", port: 60061,
  username: "admin", password: "password", graph: "mygraph"
).connect

# read — GQL text + optional named params
db.query("MATCH (n:Person) WHERE n.age > $min RETURN n.name AS name",
         params: { min: 21 }).each do |row|
  puts row["name"]
end

# write — dml stats on success, raises on a bad statement
r = db.execute("INSERT (:Person {name: 'Alice', age: 30})")
puts r.dml_stats[:inserted_nodes]   # 1

db.close
```

`query` runs a read, `execute` a write — both take GQL and optional `params`
and return a `Tina4Ultipa::Result`:

| Member | Meaning |
|---|---|
| `#columns` | column names |
| `#rows` | decoded rows (arrays of Ruby values) |
| `#to_h_rows` / `#dicts` | rows as hashes keyed by column |
| `#scalar` | first cell of the first row |
| `#rows_affected`, `#dml_stats`, `#warnings` | write metadata |

`Result` is `Enumerable` and yields each row as a hash, so `each`, `map` and
`select` work directly on a result.

Errors: a bad statement raises `Tina4Ultipa::Error`; an unreachable host raises
`Tina4Ultipa::ConnectError` within `connect_timeout`, naming host, port and elapsed time.

## Type support

Every gqldb `PropertyType` decodes to a natural Ruby value:

| Category | Types | Decodes to |
|---|---|---|
| Numeric | int32/uint32/int64/uint64, float, double | `Integer` / `Float` |
| Text | string, text | `String` |
| Boolean / null | bool, null, unset | `true`/`false` / `nil` |
| Binary | **blob** | binary `String` (e.g. an image, round-trips intact) |
| Decimal | decimal | `String` (precision-preserving) |
| Temporal | date, local/zoned time, local/zoned datetime, timestamp | ISO-8601 `String` |
| Interval | year-to-month, day-to-second | `{"months" => …}` / `{"seconds" => …, "nanoseconds" => …}` |
| Spatial | point, point3d | `{"x", "y"[, "z"], "srid"}` `Hash` |
| Vector | vector | `Array` of `Float` |
| Graph | **node**, **edge**, **path** | `Hash` (`_kind` node/edge/path; nodes/edges carry `id`, `labels`/`type`, `properties`, internal `uuid`) |
| Tabular | list, set, map, record, table | `Array` / `Hash` |
| Error | error | `{"code", "message"}` |

Node/edge hashes include the 8-byte internal-id (`uuid`) trailer emitted by
gqldb 6.1.147+.

## Protocol

`ultipa-gqldb` speaks gRPC (default port `60061`, protobuf package `gqldb`). The
driver authenticates with `SessionService.Login`, passes the returned `session_id`
on every call as the **`session-id`** metadata header (as an unsigned decimal), then
runs `QueryService.Gql`. Each value is a `TypedValue{type, bytes}`; all multi-byte
integers are little-endian. The full byte-level encoding is documented in
**[PROTOCOL.md](PROTOCOL.md)** — grounded in Ultipa's official gqldb SDK and proto,
and verified live against gqldb-grpc 6.2.130 CE.

## Sample data pack

Get a real graph into your community-edition instance in seconds - 10 people (with
photos), 3 companies, 3 projects, 5 skills and 62 relationships:

```bash
ruby examples/seed.rb ultipa://admin:PASSWORD@HOST:60061
# graph defaults to "default"; override with TINA4_ULTIPA_GRAPH
```

Then explore it:

```sql
MATCH (n:Person)-[e]->(m) RETURN n, e, m LIMIT 100
RETURN db.overview()
```

The pack lives in [`examples/`](examples/) - `people.json` describes the graph and
`sample_data/faces/*.jpg` are 64px portraits of **AI-generated, non-existent people**
([thispersondoesnotexist.com](https://thispersondoesnotexist.com)) stored as **BLOB**
properties, so it also demonstrates binary round-tripping through gqldb. Re-running is
safe - it clears the demo labels (Person/Company/Project/Skill) first.

## Testing

Real, no-mock tests run against a live server:

```bash
TINA4_TEST_ULTIPA_URL=ultipa://admin:password@host:60061 ruby test/test_driver.rb
```

They cover scalars, node/edge/list/map decoding, the full temporal/spatial/interval
set, path decoding, and a BLOB image round-trip.

## Links

- **Ultipa** — website [ultipa.com](https://www.ultipa.com) · docs [ultipa.com/docs](https://www.ultipa.com/docs) · GQL query language reference in the docs
- **Tina4** — [tina4.com](https://tina4.com) · the framework this driver powers
- **This driver** — [github.com/tina4stack/ultipa-ruby](https://github.com/tina4stack/ultipa-ruby) · sibling drivers for [Python](https://github.com/tina4stack/ultipa-python), [Node.js](https://github.com/tina4stack/ultipa-node), [PHP](https://github.com/tina4stack/ultipa-php)

## License

MIT. Note: the Ultipa community-edition server is licensed by Ultipa for personal /
non-commercial use — review [Ultipa's terms](https://www.ultipa.com) before you
deploy it. This driver is an independent client and may not be officially supported
by Ultipa.

---

Sponsored by [Code Infinity](https://codeinfinity.co.za) · part of the
[Tina4](https://tina4.com) stack.
