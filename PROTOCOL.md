# Ultipa `gqldb` gRPC wire protocol — notes

A driver-side reference for the `gqldb` gRPC wire protocol, produced **in
collaboration with Ultipa's official `gqldb` protobuf definitions and Node.js SDK**
and verified live against **`gqldb-grpc 6.2.130` (core `v1.1.412`) — Community
Edition**. Every value type documented here decodes exactly as Ultipa's own SDK does.

> Ultipa's `gqldb.proto` and SDK are the authoritative source; this file is a
> compact, language-neutral summary the `tina4-ultipa` drivers (Python / Node /
> Ruby / PHP) implement against.

## 1. Transport & session

- **gRPC**, protobuf package `gqldb`.
- `SessionService.Login(username, password, default_graph)` → `session_id` (**uint64**).
- Every later RPC carries the session as gRPC **metadata header `session-id`**,
  formatted as an **unsigned decimal string**. (Sending it as a *signed* int64 —
  which is how some protobuf runtimes surface a uint64 — yields
  `invalid session ID`.)
- `QueryService.Gql(GqlRequest)` → `GqlResponse`.

```
GqlRequest  { string gql; string graph_name; map/parameters; uint64 session_id;
              bool read_only; int32/timeout }
GqlResponse { repeated string columns; repeated Row rows; int64 rows_affected;
              DmlStats dml_stats; repeated string warnings }
Row         { repeated TypedValue values }
TypedValue  { PropertyType type; bytes data; bool is_null }
```

Every cell and every property value is a `TypedValue`. `type` selects the decoder;
`data` is a type-specific byte blob. **All multi-byte integers are little-endian.**

## 2. `PropertyType` enum (values observed)

| # | Name | # | Name |
|---|------|---|------|
| 3 | INT64 | 15 | SET |
| 7 | STRING | 16 | MAP |
| 8 | DATETIME | 21 | DATE |
| 9 | TIMESTAMP | 30 | PATH |
| 13 | DECIMAL | 32 | NODE |
| 14 | LIST | 33 | EDGE |

Also present (symbolic, standard fixed-width): INT32, UINT32, UINT64, FLOAT,
DOUBLE, BOOL, TEXT, NULL, UNSET, BLOB, POINT/geo, VECTOR, DURATION.

## 3. Scalar encodings (verified)

| PropertyType | `data` encoding |
|---|---|
| INT32 / UINT32 / INT64 / UINT64 | fixed-width little-endian two's-complement / unsigned |
| FLOAT / DOUBLE | IEEE-754 little-endian (4 / 8 bytes) |
| BOOL | 1 byte, `0x00`/`0x01` |
| STRING / TEXT | UTF-8 bytes |
| NULL / UNSET | `is_null = true` (data empty) |
| **DATE** (21) | 4 bytes: `uint16 year · uint8 month · uint8 day`. e.g. `EA 07 08 15` → `0x07EA=2026`, `08`, `0x15=21` → `2026-08-21` |
| **DATETIME** (8) / **TIMESTAMP** (9) | `uint64` unix time. Unit not self-describing; our drivers auto-detect s / ms / µs by magnitude. **Needs confirmation** (unit + timezone). |
| **DECIMAL** (13) | UTF-8 **string** of the decimal, e.g. `33 2E 31 34` = `"3.14"`. (Kept as a string to preserve precision.) |

## 4. Composite encodings (verified)

A **property block** is the repeating unit shared by NODE/EDGE properties and MAP:

```
props := uint16 count
         count × ( uint16 keyLen · key(UTF-8) ·
                   uint16 ptype  · uint32 dataLen · data(ptype-encoded) )
```

| PropertyType | `data` encoding |
|---|---|
| **LIST** (14) / **SET** (15) | `uint16 count · count × ( uint16 ptype · uint32 len · data )` |
| **MAP** (16) | a **props block** (byte-identical to the one above) |
| **NODE** (32) | `uint16 uuidLen · uuid(UTF-8) · uint16 labelCount · labelCount × (uint16 len · label) · «props block» · 8-byte trailing id` |
| **EDGE** (33) | `id · type · fromUuid · toUuid` (each `uint16 len · UTF-8`) · `«props block»` · 8-byte trailer |

Values inside LIST/SET/MAP/props recurse through the same `ptype`-dispatched
decoder, so arbitrary nesting works (e.g. `db.overview()` returns
`MAP{ labelCounts: LIST[ MAP{label,count,type} ], edgePatterns: LIST[ MAP{…} ] }`).

## 5. Temporal / spatial / interval (verified against the official SDK + live 6.2.130)

All confirmed against the official `gqldb-nodejs` SDK decoder and live queries.

| PropertyType | `data` encoding |
|---|---|
| **DATE** (21) | `int16 year · u8 month · u8 day` |
| **LOCAL_TIME** (23) | `u8 h · u8 m · u8 s · [pad] · u32 nanos@4` |
| **ZONED_TIME** (22) | LOCAL_TIME + `int16 offsetMinutes@8` |
| **LOCAL_DATETIME** (19) / **DATETIME** (8, *deprecated*) | `int16 year · u8 m,d,h,mi,s · u32 nanos@7` (11 bytes); 8-byte legacy = u64 unix |
| **ZONED_DATETIME** (20) | LOCAL_DATETIME + `int16 offsetMinutes@11` (13 bytes) |
| **TIMESTAMP** (9) | `int64 secs@0 · u32 nanos@8` (12 bytes); 8-byte legacy = u64 unix |
| **YEAR_TO_MONTH** (24) | `int32 months` |
| **DAY_TO_SECOND** (25) | `int64 secs@0 · u32 nanos@8` |
| **POINT** (12) | `double x@0 · double y@8 · u32 srid@16` (20 bytes; srid 7203 cartesian / 4326 geographic) |
| **POINT3D** (27) | `double x · double y · double z · u32 srid@24` |
| **VECTOR** (28) | `u32 dim · dim × float32` |
| **PATH** (30) | `u16 nodeCount · (u32 len · nodeData)… · u16 edgeCount · (u32 len · edgeData)…` |
| **TABLE** (29) | `u16 colCount · cols(str)… · u16 rowCount · (u16 cellCount · TVE…)…` |
| **RECORD** (26) | a property block (== MAP) |
| **ERROR** (31) | UTF-8 JSON `{code, message}` |
| **BLOB** (11) | raw bytes (passthrough) — e.g. an image stored on a node round-trips byte-for-byte |

Node/Edge carry an optional **8-byte little-endian uint64 internal-id trailer**
(gqldb 6.1.147+) after the property block; absent on older servers.

### Still unmapped
- **POINT variants beyond POINT/POINT3D**, and any future types → drivers return raw bytes.
- TIMESTAMP/DATETIME unit & timezone edge cases across server versions still worth confirming with Ultipa.

## 6. DML stats

`DmlStats { inserted_nodes; inserted_edges; deleted_nodes; deleted_edges;
set_nodes; set_edges }` — all int64 counts, returned on write statements
(`INSERT`, `SET`, `DETACH DELETE`, …).

---

*Generated for the tina4-ultipa driver family (python/node/ruby/php). Corrections
from an official Ultipa spec supersede everything here.*
