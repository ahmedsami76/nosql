# NoSQL Series — Part 2: Document Stores, with MongoDB

**Level:** practitioner · assumes **no prior knowledge** of document stores or MongoDB
**Platform:** K3s (single-node Kubernetes)
**Tooling:** `mongosh` · mongo-express (browser GUI) · MongoDB Compass (desktop, optional) · JupyterLab + Python (PyMongo)
**You do need:** working SQL, basic Linux, basic containers, basic `kubectl`
**Helpful but not required:** Module 1 (Redis / key-value stores)

---

## Contents

| Part | What it answers |
|---|---|
| **0 — Orientation** | What are we building, and in what order? |
| **1 — Document stores** | What is this model, why does it exist, and how does it store bytes? |
| **2 — Meet MongoDB** | What is MongoDB specifically, and what is BSON? |
| **3 — Stand it up** | A real 3-member replica set on Kubernetes |
| **4 — Three ways in** | Connect · validate · administer · author, from three clients |
| **5 — The mental model** | The object hierarchy that replaces server→database→table→row |
| **6 — CRUD** | Create, read, update, delete — in `mongosh`, then the GUI, then PyMongo |
| **7 — Beyond CRUD** | Indexes, the aggregation pipeline, transactions, change streams, schema validation |
| **8 — Enterprise features** | Replication, elections, read/write concerns, sharding, horizontal scale |
| **9 — Where next** | The rest of the series |
| **Appendices** | Troubleshooting · teardown · command reference |

---

## Part 0 — Orientation

Everything runs on **one K3s node**. As in Module 1, we use Kubernetes rather than plain Docker because the operational questions that matter — stable identity, persistent volumes, probes, secrets, service discovery, ordered rollout — only become visible in an orchestrator.

**One important difference from the Redis module:** we deploy a **3-member replica set**, not a single server. That is not gold-plating. In MongoDB, three headline features are **unavailable on a standalone server**:

- **Multi-document transactions** require a replica set
- **Change streams** require a replica set
- **Causal consistency / read-your-writes sessions** require a replica set

A standalone `mongod` would force us to skip Part 7 and most of Part 8. So the lab is a replica set from the first `kubectl apply`, and Part 8 stops being theory.

One namespace, four workloads:

| Workload | Kind | In-cluster address | Purpose |
|---|---|---|---|
| MongoDB | StatefulSet (3 replicas) | `mongodb-0.mongodb-headless.mongo-lab.svc.cluster.local:27017` | The database |
| RS initialiser | Job | — | Runs `rs.initiate()` once, then exits |
| mongo-express | Deployment | `mongo-express.mongo-lab.svc.cluster.local:8081` | Browser GUI |
| JupyterLab | Deployment | `jupyter.mongo-lab.svc.cluster.local:8888` | Python notebooks (PyMongo) |

Reachable from your host two ways — use whichever works:

| Workload | NodePort | `kubectl port-forward` |
|---|---|---|
| MongoDB | `localhost:30017` | `localhost:27017` |
| mongo-express | `http://localhost:30081` | `http://localhost:8081` |
| JupyterLab | `http://localhost:30089` | `http://localhost:8888` |

```
nosql-course/
└── 02-document-mongodb/
    ├── preflight.sh                     # host readiness check (3.1)
    ├── k3s/
    │   ├── 00-namespace.yaml
    │   ├── 10-mongodb-config.yaml       # ConfigMap (mongod.conf) + Secrets (root pw, keyfile)
    │   ├── 20-mongodb-statefulset.yaml  # 3-member replica set
    │   ├── 30-mongodb-service.yaml      # headless + ClusterIP + NodePort
    │   ├── 40-mongodb-init-job.yaml     # rs.initiate() + create the app user
    │   ├── 50-mongo-express.yaml
    │   └── 60-jupyter.yaml
    └── notebooks/
```

> **Namespace note.** This module uses `mongo-lab`, not `nosql-lab`, so it can run **alongside** the Redis lab from Module 1 without a name or NodePort collision. If you're tight on RAM, tear down Module 1 first.

**The arc.** Parts 1–2 are conceptual: what a document store is, and what MongoDB is. Part 3 stands up the replica set. Part 4 is three clients, four verbs each. Part 5 is the mental model. Part 6 is CRUD three ways. Part 7 is what you'd actually reach for in production. Part 8 is replication and sharding, demonstrated rather than described.

*Recording note:* Part 4 is the natural chapter break, as in Module 1.

---

## Part 1 — Document stores from first principles

### 1.1 What a document store is

A document store keeps data as **self-describing, hierarchical documents** — typically JSON-shaped — retrieved by key **or by querying inside the document**.

That last clause is the whole thing. Here's Module 1's diagram, extended:

```
KEY-VALUE STORE                       DOCUMENT STORE
───────────────                       ──────────────
"customer:C00001"                     _id: "C00001"
      │                                     │
      ▼                                     ▼
 ┌──────────────┐                   ┌──────────────────────────┐
 │ ????????????? │  opaque bytes    │ { "name": "Ava",         │  engine can
 │ ????????????? │  the engine      │   "tier": "gold",        │  SEE, INDEX,
 │ ????????????? │  cannot see      │   "address": {           │  and QUERY
 └──────────────┘  inside           │     "city": "Houston" }, │  every field
                                    │   "orders": [ ... ] }    │
 Query: GET by key. Full stop.      └──────────────────────────┘
                                     Query: by _id, by any field, by nested
                                     path, by array element, by range, by
                                     regex, by geospatial proximity...
```

Four properties define the model:

- **The value is transparent.** The engine parses the document and can index any field, at any depth, including inside arrays.
- **Documents are self-describing.** Each carries its own field names and types. Two documents in the same collection need not have the same shape.
- **Nesting is native.** A document holds sub-documents and arrays of sub-documents. There is no join needed to retrieve a whole entity.
- **The document is the unit of atomicity.** A single-document write is always atomic, no matter how deeply nested.

That last point connects directly to Module 1's `NoSQL Distilled` framing: **the document is an aggregate.** It is the unit of retrieval, the unit of distribution (the shard key lives in it), and the unit of atomicity. Everything else in this module is a consequence.

**Where it sits in the family tree** — the same table from Module 1, with our row highlighted:

| Family | Key structure | Value visibility to engine | Query capability |
|---|---|---|---|
| Key-value | Single opaque key | None — opaque blob | Point get/put/delete |
| **Document** | **Single key (`_id`)** | **Full — parsed JSON/BSON** | **Rich filters, secondary indexes, aggregation** |
| Wide-column | Composite (partition + clustering) | Partial — typed columns | Partition-scoped range scans |
| Graph | Node/edge identity | Full — typed properties | Traversals, pattern matching |

> **A document store is a key-value store that agreed to parse the value.** Everything MongoDB can do that Redis cannot — secondary indexes it maintains for you, ad-hoc queries, aggregation, schema validation — follows from that single concession.

### 1.2 Why the workload requires one

**1. The data is genuinely hierarchical, and flattening it costs you.**
An order *has* line items. A customer *has* addresses and preferences. In relational modelling that's three tables and two joins on every read. In a KV store you flatten it into dotted field names and lose the structure (we did exactly that in Module 1 — `address.city` became a literal hash field name). A document keeps the shape the domain actually has.

**2. Records are non-uniform, and the variation is the point.**
A product catalogue where a laptop has `ram_gb` and `screen_size`, a book has `isbn` and `page_count`, and a jacket has `size` and `material`. In relational modelling this is the sparse-column problem, the EAV anti-pattern, or a table per category. In a document store it is just… documents.

**3. The read pattern is "give me this whole entity."**
One round trip fetches the customer, their address, their preferences, and their recent orders — no joins, no N+1, no ORM lazy-loading surprises. This is the aggregate payoff.

**4. The schema evolves faster than the release cycle.**
Adding a field is a write, not a migration. There's no `ALTER TABLE` on a billion rows and no maintenance window. **This is a real benefit and a real debt** — see §1.4.

**5. You need ad-hoc queries that a KV store cannot answer.**
This is the specific gap that pushes a team from Redis to MongoDB. "Find all orders containing a line item over $500" needs no pre-built index in MongoDB. In Redis it is either impossible or a full `SCAN`.

> **Rule of thumb:** if your data has a natural nested shape, your records vary, and you need to query *inside* the value — a document store is the correct default.

### 1.3 Why not just a key-value store

Module 1 built the retail dataset in Redis. It worked. Here is what it cost, item by item:

| What we did in Redis | What MongoDB does |
|---|---|
| **Flattened** `address: {city, state}` into `address.city`, `address.state` hash fields | Stores the sub-document. `db.customers.find({"address.city": "Houston"})` just works |
| **Joined arrays with `\|`** for `preferences.categories` | Native array, queryable with `$in`, `$all`, `$elemMatch` |
| **Hand-built** `retail:idx:customer:tier:gold` as a Set, and maintained both sides on every write | `db.customers.createIndex({tier: 1})`. The engine maintains it |
| **Hand-built** `retail:idx:product:price` as a Sorted Set for range queries | `db.products.createIndex({price: 1})`, then `find({price: {$gte: 100, $lte: 500}})` |
| **Stored line items** as a List of JSON strings, opaque to the engine | Native array of sub-documents, indexable and queryable per element |
| **Could not answer** "orders with a line item over $500" without a new index | `find({"items.line_total": {$gt: 500}})` |
| **Application-side joins**, pipelined | `$lookup` in the aggregation pipeline (use sparingly — see §7.3) |

The single sentence: **in Redis you own your secondary indexes; in MongoDB the engine owns them.** That's the trade — you give up microsecond point-lookup latency and get a query engine.

### 1.4 Why not just a relational database

The honest comparison. MongoDB is not "faster Postgres," and pretending otherwise produces bad architecture.

| Dimension | Relational (OLTP) | Document store |
|---|---|---|
| Schema enforcement | **Engine, at write.** Migrations required | Application, or **opt-in** JSON Schema validators |
| Nested data | Normalised into child tables + joins | **Native** |
| Non-uniform records | Sparse columns, EAV, or table-per-type | **Native** |
| Read one whole entity | 1 query + N joins | **1 query, no joins** |
| Ad-hoc query across entities | **Excellent** — the planner is the point | Good within a collection; **`$lookup` is weaker than a real join** |
| Multi-entity transactions | **Excellent, cheap** | Available (4.0+), **but designed to be rare** |
| Referential integrity | **Engine-enforced FKs, cascades** | **None.** Your application's job |
| Horizontal scale | Hard — joins and FKs cross shards | **Native sharding** |
| Aggregation / analytics | **Excellent (SQL, window functions)** | Good (aggregation pipeline), less expressive |

**The three costs you accept:**

- **No referential integrity.** Delete a customer and their orders still reference the missing `customer_id`. Nothing stops you. Nothing tells you.
- **Schema-on-read failure modes are silent.** A field that becomes a string where your code expects a number produces a *wrong answer*, not an exception. (Module 1, §3.1 — the same lesson.)
- **`$lookup` is not a join.** It is a left-outer-join-shaped aggregation stage. It cannot use an index on the foreign side as flexibly as a relational planner, and joining three collections is a design smell, not a feature.

**The honest counter-argument.** PostgreSQL has stored binary JSON with GIN indexing since 9.4. If your dataset is 40 GB, mostly rectangular with a few flexible attributes, and you already run Postgres — **use `jsonb`**. Reach for MongoDB when the *dominant* shape is documents, when records genuinely vary, or when you have measured a need for horizontal write scale.

> As in Module 1: the mature architecture is often **both**. A relational system of record, a document store for the document-shaped workload, and CDC between them. Never a dual write.

### 1.5 How document data lands on disk

MongoDB's storage engine is **WiredTiger**, and knowing three things about it explains most performance behaviour.

**1. It's a B+ tree, not an LSM tree.** (WiredTiger *can* do LSM, but MongoDB does not ship it that way.) So the profile from Module 1, §1.4 Model C applies: excellent point reads and **native range scans**, at the cost of random page I/O on writes.

**2. Document-level concurrency via MVCC.** WiredTiger keeps multiple versions and uses optimistic concurrency at **document granularity** — not collection, not database. Two writers touching different documents in the same collection do not block each other. Conflicting writers get a `WriteConflict` and the server **retries internally**, transparently.

> This is a genuine contrast with Module 1's Redis: Redis gets atomicity from *being single-threaded*; MongoDB gets it from MVCC and document-level locking. Redis serialises everything; MongoDB runs many operations concurrently and resolves conflicts.

**3. The working set should fit in RAM — but the dataset need not.** WiredTiger's **cache** defaults to `max(50% of (RAM − 1 GB), 256 MB)`. Unlike Redis, data larger than RAM is normal and fine; you just pay disk I/O for cache misses. **Capacity planning is a working-set exercise**, not a total-data exercise.

Two more mechanics worth naming now, because they surface in Part 8:

- **Journaling.** Writes go to an in-memory buffer and a write-ahead journal; the journal is synced to disk **every 100 ms** by default, and a checkpoint writes a consistent snapshot **every 60 seconds**. Your durability window is therefore ≤100 ms on one node — and `writeConcern` (§8.4) lets you extend the guarantee across nodes.
- **Compression on by default.** Collections use **snappy** block compression; indexes use **prefix compression**. `zstd` is available for better ratios at more CPU. This is why a MongoDB dataset on disk is often much smaller than the same data in JSON.

---

## Part 2 — Meet MongoDB

### 2.1 What MongoDB is, and where it came from

**MongoDB** — from *humongous* — is a distributed document database.

- **2007** — started at **10gen** by Dwight Merriman, Eliot Horowitz, and Kevin Ryan. The original goal was **not** a database: they were building a platform-as-a-service, and the document store was the storage layer underneath it.
- **2009** — they open-sourced the storage layer, and it immediately mattered more than the PaaS. The company eventually renamed itself MongoDB Inc.
- **The founding insight:** application objects are nested and irregular; tables are flat and uniform; the impedance mismatch between them is where a huge share of application code goes. **Store the object.**
- **2015 — WiredTiger.** MongoDB acquired WiredTiger and made it the default engine in 3.2, replacing MMAPv1. This is when document-level concurrency and compression arrived, and it's the single biggest quality jump in the product's history.
- **2018 — multi-document ACID transactions** on replica sets (4.0); extended to sharded clusters in 4.2 (2019). The "MongoDB doesn't have transactions" claim has been out of date for years.

**Licensing — this matters for enterprise adoption.** MongoDB moved from AGPL to the **SSPL** (Server Side Public License) in 2018. SSPL is *not* OSI-approved. Practically:

- **Using MongoDB** in your product, self-hosted or in Atlas — unaffected. Teaching, dev, and internal enterprise use are fine.
- **Offering MongoDB as a public managed service** triggers SSPL §13, which requires open-sourcing your entire service stack.
- That clause is why AWS built **DocumentDB** (wire-protocol compatible, different engine) rather than reselling MongoDB.
- **FerretDB** is an open-source proxy translating the MongoDB wire protocol onto PostgreSQL, if the licence is a blocker.

Everything in this module works against the community edition.

### 2.2 BSON — the format underneath

Documents look like JSON. They are stored as **BSON** (Binary JSON), and the difference is not cosmetic.

| | JSON | BSON |
|---|---|---|
| Encoding | Text | **Binary** |
| Numeric types | One (`double`) | `int32`, `int64`, `double`, **`decimal128`** |
| Dates | A string, by convention | **Native `Date` type** |
| Binary data | Base64 in a string | **Native `BinData`** |
| Traversal | Must parse the whole thing | **Length-prefixed — skip fields without parsing** |
| Size limit | — | **16 MB per document** |

Three consequences you will actually hit:

- **`decimal128` exists — use it for money.** `double` cannot represent `0.1` exactly. `NumberDecimal("0.1")` can. Storing currency as a `double` is a real bug that ships to production regularly.
- **Dates are real dates.** Range queries, `$year`/`$month` operators, and TTL indexes all work because the type is native. Storing an ISO string instead throws that away.
- **16 MB is a hard ceiling.** This is the aggregate-boundary limit from Module 1, §2.4, in concrete form. **An unbounded array inside a document is the #1 document-modelling failure**, and the fix is the same: bucketing, or a reference.

```javascript
// The types that matter, and why. Run this in mongosh in Part 4.
db.types_demo.insertOne({
  _id:        "demo",
  an_int:     NumberInt(42),           // int32  — compact
  a_long:     NumberLong("9007199254740993"),  // int64 — beyond double's exact range
  a_double:   3.14159,                 // float64 — DO NOT use for money
  money:      NumberDecimal("249.99"), // decimal128 — exact. USE THIS FOR MONEY.
  when:       new Date(),              // native Date, not a string
  oid:        new ObjectId(),          // 12-byte id with an embedded timestamp
  nothing:    null,                    // null is a VALUE...
  // ...and an ABSENT field is a different thing entirely. {a: null} and {}
  // are distinct documents, and they match different queries. This trips
  // people up constantly — see 6.3.
});
```

**A word on `_id` and `ObjectId`.** Every document has an `_id`, unique within its collection, immutable, and indexed automatically — you cannot drop that index. If you don't supply one, the driver generates an **`ObjectId`**: 12 bytes = 4-byte Unix timestamp + 5 bytes of random + 3-byte counter.

That structure has two practical consequences: `ObjectId`s are **roughly sortable by creation time** (`_id.getTimestamp()` gives you a free `created_at`), and they are **monotonically increasing** — which makes `_id` a *terrible* shard key, because every insert lands on the same shard. That's the monotonic-key hotspot from Module 1, §4.2. We return to it in §8.6.

### 2.3 Internal architecture

```mermaid
flowchart TB
    subgraph CLIENTS["Clients"]
        C1["mongosh"]
        C2["PyMongo / drivers"]
        C3["Compass / mongo-express"]
    end

    subgraph MONGOD["mongod process"]
        NET["Network layer<br/>MongoDB Wire Protocol over TCP<br/>one thread per connection (default)"]
        AUTH["Authentication + RBAC<br/>SCRAM-SHA-256 · x.509 · roles"]
        CMD["Command dispatch"]
        QP["QUERY PLANNER<br/>candidate plans → trial execution →<br/>winner cached in the PLAN CACHE"]
        subgraph STORAGE["WiredTiger storage engine"]
            CACHE["WT cache (~50% of RAM−1GB)<br/>uncompressed pages + MVCC versions"]
            BTREE["B+ trees<br/>one per collection, one per index"]
            JOURNAL["Journal (WAL)<br/>synced every 100 ms"]
            CKPT["Checkpoints<br/>every 60 s"]
            COMPRESS["snappy (data) · prefix (indexes)"]
        end
        REPL["Replication subsystem<br/>OPLOG (capped collection)<br/>elections · heartbeats"]
        subgraph BG["Background"]
            TTL["TTL monitor (every 60 s)"]
            IDXB["Index builds"]
            CS["Change stream cursors"]
        end
    end

    DISK[("dbPath on the PersistentVolume<br/>collection-*.wt · index-*.wt · journal/")]
    SECONDARY["Secondary mongod<br/>tails the oplog"]

    C1 --> NET
    C2 --> NET
    C3 --> NET
    NET --> AUTH --> CMD --> QP --> BTREE
    BTREE --> CACHE
    CACHE --> JOURNAL --> DISK
    CACHE --> CKPT --> DISK
    BTREE --> COMPRESS
    CMD --> REPL --> SECONDARY
    REPL --> CS
    TTL --> BTREE
```

**The pieces that matter:**

**1. One thread per connection.** MongoDB is *not* single-threaded (contrast Redis). Concurrency is real, and it is controlled by MVCC at document granularity. The practical consequence is that **connection count matters** — thousands of idle connections cost real memory, which is why every driver pools by default and why `maxPoolSize` is a tuning knob you should know exists.

**2. The query planner and the plan cache.** For a new query shape, MongoDB generates candidate plans, runs them **in parallel for a trial period**, picks the winner empirically, and caches it keyed by query *shape*. Two consequences: `explain()` is how you find out what actually happened, and a plan can be **evicted and re-chosen** after index changes or enough write volume. If a query is mysteriously slow today and was fast yesterday, the plan cache is the first place to look.

**3. The oplog is a capped collection.** Replication is not a separate binary format — it is a **collection you can query** (`local.oplog.rs`). Secondaries tail it. Change streams (§7.5) are a supported API over the same stream. Being able to `db.getSiblingDB("local").oplog.rs.find()` and *see* replication is a genuinely good teaching moment, and we use it in §8.2.

**4. Idempotent oplog entries.** An update like `{$inc: {n: 1}}` is rewritten in the oplog as a **`$set` to the resulting value**, so replaying it twice is safe. That's what makes crash recovery and initial sync work.

**5. TTL is a background monitor, not an instant delete.** A TTL index is checked **every 60 seconds**. Documents expire *at or after* their TTL, never before, but "at or after" can mean up to a minute late. Same lesson as Redis's probabilistic expiry (Module 1, §5.5): **never depend on exact-moment expiry.**

### 2.4 The MongoDB feature map

```mermaid
mindmap
  root((MongoDB))
    Data Model
      BSON documents
      Nested sub-documents
      Arrays of sub-documents
      decimal128 / Date / ObjectId
      16 MB document limit
    Querying
      find with rich operators
      Aggregation Pipeline
      Text search
      Geospatial 2dsphere
      Atlas Search / Vector Search
    Indexes
      Single field
      Compound
      Multikey (arrays)
      Text
      Geospatial
      Hashed
      Partial and Sparse
      TTL
      Unique
      Wildcard
    Consistency
      Read concern
      Write concern
      Causal sessions
      Multi-document ACID transactions
    Replication
      Replica sets
      Oplog
      Elections (Raft-like)
      Read preference
      Hidden / delayed / arbiter members
    Sharding
      Shard keys (ranged / hashed)
      Chunks and balancer
      mongos routers
      Config servers
      Zone sharding
    Operations
      RBAC users and roles
      SCRAM / x.509 / LDAP
      Encryption at rest and in transit
      Change streams
      Schema validation
      Profiler and explain
```

---

## Part 3 — Stand up the replica set on K3s

### 3.1 Validate the host first

MongoDB's footprint is larger than Redis's — three `mongod` processes plus Jupyter plus mongo-express. **Run this before installing anything.**

```bash
#!/usr/bin/env bash
# preflight.sh — validates the host can run the MongoDB-on-K3s lab.
set -uo pipefail
PASS=0; FAIL=0; WARN=0
ok(){   echo "  [ OK ]   $1"; PASS=$((PASS+1)); }
warn(){ echo "  [ WARN ] $1"; WARN=$((WARN+1)); }
bad(){  echo "  [ FAIL ] $1"; FAIL=$((FAIL+1)); }
hdr(){  echo; echo "=== $1 ==="; }

hdr "1. Operating system"
OS="$(uname -s)"
case "$OS" in
  Linux)  ok "Linux $(uname -r) — native K3s supported." ;;
  Darwin) warn "macOS — K3s needs Linux. Use k3d or Multipass." ;;
  *)      warn "Unrecognized OS '$OS' — use k3d or a Linux VM." ;;
esac

hdr "2. Hardware — 3 mongod + Jupyter + mongo-express"
CPUS=$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 0)
[ "$CPUS" -ge 4 ] && ok "CPU cores: $CPUS" \
                  || warn "CPU cores: $CPUS — 4+ recommended for a 3-member set"
if [ "$OS" = "Linux" ]; then
  MEM_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
else
  MEM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
fi
# 3 x 1.5Gi mongod limits + 2Gi Jupyter + 0.5Gi mongo-express ≈ 7 GB of limits.
[ "$MEM_MB" -ge 8192 ] && ok "RAM: ${MEM_MB} MB" \
  || warn "RAM: ${MEM_MB} MB — tight for 3 members. Set replicas: 1 in 20-*.yaml"
DISK_MB=$(df -Pm . | awk 'NR==2 {print $4}')
# 3 x 5Gi mongod PVCs + 3Gi Jupyter + images.
[ "$DISK_MB" -ge 25600 ] && ok "Free disk: ${DISK_MB} MB" \
                         || bad "Free disk: ${DISK_MB} MB (need >= 25 GB)"

hdr "3. Kubernetes"
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  ok "Cluster reachable."
  NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv ' Ready ')
  [ "$NOT_READY" -eq 0 ] && ok "All nodes Ready." || bad "$NOT_READY node(s) NOT Ready."
  kubectl get storageclass 2>/dev/null | grep -q '(default)' \
    && ok "Default StorageClass present." \
    || warn "No default StorageClass — the 4 PVCs will stay Pending."
  # A single-node cluster must allow 3 StatefulSet pods to co-schedule. We set
  # no anti-affinity precisely so this works — production WOULD set it.
  ok "Note: no pod anti-affinity is set, so all 3 members land on one node."
else
  warn "No reachable cluster — install K3s first."
fi

hdr "4. NodePort availability"
check_port(){
  local p=$1 svc=$2
  if command -v ss >/dev/null 2>&1; then L=$(ss -ltn 2>/dev/null | grep -c ":$p ")
  else L=0; fi
  [ "$L" -eq 0 ] && ok "Port $p free (for $svc)" || bad "Port $p IN USE (needed by $svc)."
}
check_port 30017 "MongoDB"; check_port 30081 "mongo-express"; check_port 30089 "JupyterLab"

hdr "5. Kernel settings MongoDB cares about (node-level)"
if [ "$OS" = "Linux" ]; then
  # THP causes latency spikes and inflated RSS for MongoDB. The official docs
  # are unambiguous: disable it.
  THP=/sys/kernel/mm/transparent_hugepage/enabled
  if [ -r "$THP" ]; then
    grep -q '\[never\]' "$THP" && ok "THP disabled" \
      || warn "THP enabled — MongoDB requires it OFF: echo never | sudo tee $THP"
  fi
  # WiredTiger opens a file per collection AND per index. Default ulimits are
  # far too low for a real dataset.
  NOFILE=$(ulimit -n)
  [ "$NOFILE" -ge 64000 ] && ok "open files: $NOFILE" \
    || warn "open files: $NOFILE (<64000). WiredTiger opens 2 files per collection+index."
  # Prefer to reclaim page cache over swapping out the WT cache.
  SW=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
  [ "$SW" -le 10 ] 2>/dev/null && ok "vm.swappiness=$SW" \
    || warn "vm.swappiness=$SW — set to 1: sudo sysctl -w vm.swappiness=1"
else
  warn "Skipped — tune inside the VM that runs K3s."
fi

echo; echo "  Passed: $PASS   Warnings: $WARN   Failures: $FAIL"
[ "$FAIL" -gt 0 ] && { echo "  NOT READY."; exit 1; }
echo "  READY."; exit 0
```

Apply the node tuning:

```bash
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
sudo sysctl -w vm.swappiness=1
printf 'vm.swappiness=1\n' | sudo tee /etc/sysctl.d/99-mongodb.conf
```

> **THP is not optional for MongoDB.** The official documentation requires it disabled; leaving it on produces latency spikes and inflated RSS that look like a MongoDB bug. Same class of node-level dependency as Redis's `vm.overcommit_memory` in Module 1.

### 3.2 Generate a real keyfile

The manifest ships with a placeholder so it applies cleanly. **Replace it before any real use:**

```bash
# 6–1024 base64 characters. Every member must present the IDENTICAL value.
KEYFILE=$(openssl rand -base64 756 | tr -d '\n')

# Patch it into the manifest (or edit 10-mongodb-config.yaml by hand).
kubectl -n mongo-lab create secret generic mongodb-keyfile \
  --from-literal=keyfile="$KEYFILE" \
  --dry-run=client -o yaml > /tmp/keyfile-secret.yaml
```

> **Why a keyfile at all?** Enabling `security.authorization` also enables **internal authentication** between replica-set members. Without a shared secret, members refuse to talk to each other and the set never forms. The keyfile is the simplest mechanism; x.509 certificates are the production alternative.

### 3.3 Apply

```bash
cd nosql-course/02-document-mongodb

kubectl apply -f k3s/

# 1. The StatefulSet first. All 3 members must be Running before the Job runs.
kubectl -n mongo-lab rollout status statefulset/mongodb --timeout=300s

# 2. The init Job forms the replica set and creates the users.
kubectl -n mongo-lab wait --for=condition=complete job/mongodb-init --timeout=300s
kubectl -n mongo-lab logs job/mongodb-init      # read this — it is instructive

# 3. The clients.
kubectl -n mongo-lab rollout status deployment/mongo-express --timeout=180s
kubectl -n mongo-lab rollout status deployment/jupyter       --timeout=300s

kubectl -n mongo-lab get pods,svc,pvc -o wide
```

Expected:

```
NAME                                 READY   STATUS      RESTARTS   AGE
pod/mongodb-0                        1/1     Running     0          3m
pod/mongodb-1                        1/1     Running     0          3m
pod/mongodb-2                        1/1     Running     0          3m
pod/mongodb-init-x7k2p               0/1     Completed   0          2m
pod/mongo-express-6c9d7f8b45-x2k9p   1/1     Running     0          2m
pod/jupyter-7f4b8c6d92-lm4rt         1/1     Running     0          2m
```

> **Read the init Job's log out loud.** It walks the entire bootstrap: waiting for three processes, `rs.initiate()`, waiting for an election, creating the root user through the localhost exception, then creating a least-privilege app user *as* root. That sequence is the whole authentication story in one screen.

### 3.4 Validate the replica set

This is the step that separates "the pods are Running" from "the database works."

```bash
# --- 1. Is there a PRIMARY, and who is it? ---
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
  --eval 'rs.status().members.forEach(m => print(m.name.split(".")[0] + "  ->  " + m.stateStr))'
# Expect:
#   mongodb-0  ->  PRIMARY
#   mongodb-1  ->  SECONDARY
#   mongodb-2  ->  SECONDARY
```

```bash
# --- 2. The single most useful diagnostic command in MongoDB ---
# db.hello() replaced the old db.isMaster(). It tells you the topology as the
# SERVER sees it, which is what drivers use for routing.
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin --eval '
  const h = db.hello();
  print("setName          : " + h.setName);
  print("isWritablePrimary: " + h.isWritablePrimary);
  print("primary          : " + h.primary);
  print("hosts            : " + h.hosts.join("\n                   "));
'
```

```bash
# --- 3. Replication lag. On a healthy idle lab this is 0s. ---
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
  --eval 'rs.printSecondaryReplicationInfo()'

# --- 4. The oplog window — how far behind a secondary may fall and still
#        catch up incrementally, rather than needing a full initial sync. ---
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
  --eval 'rs.printReplicationInfo()'

# --- 5. Prove the config uses HOSTNAMES, not pod IPs. This is the check that
#        catches the most damaging misconfiguration in the whole module. ---
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
  --eval 'rs.conf().members.forEach(m => print(m._id + ": " + m.host))'
# Every host MUST look like mongodb-N.mongodb-headless.mongo-lab.svc.cluster.local:27017
# If you see an IP address, the set WILL break on the next pod reschedule.
```

```bash
# --- 6. Authentication actually works, and RBAC is real. ---
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
  --eval 'db.getSiblingDB("admin").getUsers().users.forEach(
            u => print(u.user + "  roles: " +
                       u.roles.map(r => r.role + "@" + r.db).join(", ")))'
# Expect:
#   admin       roles: root@admin
#   retail_app  roles: readWrite@retail, dbAdmin@retail

# --- 7. Unauthenticated access is refused. Prove it, do not assume it. ---
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  --eval 'db.getSiblingDB("retail").customers.countDocuments()' 2>&1 | tail -2
# Expect: MongoServerError: Command count requires authentication
```

### 3.5 Essential post-installation steps

Four things that are easy to skip and painful to add later.

**1. Write a document and prove it replicated.** This is the moment the lab becomes real:

```bash
# Write to the PRIMARY with w:majority — the write does not return until a
# majority of members have acknowledged it.
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin retail --eval '
  db.smoketest.insertOne({ _id: "hello", at: new Date() },
                         { writeConcern: { w: "majority", wtimeout: 5000 } });
  print("written to primary");
'

# Read it from a SECONDARY. Secondaries reject reads by default — you must opt
# in with readPreference, which is itself the lesson.
kubectl -n mongo-lab exec mongodb-1 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin retail --eval '
  db.getMongo().setReadPref("secondary");
  printjson(db.smoketest.findOne({ _id: "hello" }));
'
```

**2. Create the `retail` database and its indexes.** MongoDB creates a database lazily on first write, so there is nothing to "create" — but the indexes matter:

```bash
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u retail_app -p 'RetailApp2026!' --authenticationDatabase admin retail --eval '
  db.customers.createIndex({ tier: 1 });
  db.customers.createIndex({ "address.city": 1 });
  db.products.createIndex({ category: 1, price: -1 });
  db.orders.createIndex({ customer_id: 1, order_ts: -1 });
  db.orders.createIndex({ "items.sku": 1 });
  print("indexes created");
'
```

**3. Verify the app user cannot exceed its grant.** RBAC demonstrated, not described:

```bash
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u retail_app -p 'RetailApp2026!' --authenticationDatabase admin \
  --eval 'db.getSiblingDB("admin").system.users.find().toArray()' 2>&1 | tail -3
# Expect: MongoServerError: not authorized on admin to execute command
```

**4. Know your backup story before you need it.** For this lab:

```bash
# mongodump against the PRIMARY, written inside the pod, then copied out.
kubectl -n mongo-lab exec mongodb-0 -- mongodump \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
  --db retail --archive=/tmp/retail.archive --gzip
kubectl -n mongo-lab cp mongodb-0:/tmp/retail.archive ./retail.archive

# Restore:
# kubectl -n mongo-lab cp ./retail.archive mongodb-0:/tmp/retail.archive
# kubectl -n mongo-lab exec mongodb-0 -- mongorestore \
#   -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
#   --archive=/tmp/retail.archive --gzip --drop
```

> **`mongodump` is a logical backup and it is not point-in-time consistent across collections** unless you add `--oplog`. For production, use filesystem/volume snapshots of a *stopped or hidden* secondary, or Atlas/Ops Manager continuous backup. Saying this out loud prevents a very expensive misunderstanding.

### 3.6 Reaching the lab from your host

| Client runs… | Host | Port | Notes |
|---|---|---|---|
| Inside the cluster | `mongodb-0.mongodb-headless.mongo-lab.svc.cluster.local` | 27017 | Full replica-set semantics |
| Inside the cluster (any member) | `mongodb` (ClusterIP) | 27017 | Round-robins — **writes may hit a secondary** |
| On your host, via NodePort | `localhost` | 30017 | **Must use `directConnection=true`** |
| On your host, via port-forward | `localhost` | 27017 | Same caveat |
| Inside the mongod pod | `127.0.0.1` | 27017 | `kubectl exec` |

```bash
kubectl -n mongo-lab port-forward svc/mongodb       27017:27017 &
kubectl -n mongo-lab port-forward svc/mongo-express  8081:8081 &
kubectl -n mongo-lab port-forward svc/jupyter        8888:8888 &
```

> **The trap that catches everyone, and it is different from Module 1's.** In Redis, a NodePort just worked. In MongoDB, a **replica-set-aware client connecting through a NodePort receives the set's member list during handshake** — and those are in-cluster DNS names your host cannot resolve. The client dutifully tries to reach `mongodb-0.mongodb-headless.mongo-lab.svc...` and fails, *after* a successful TCP connection.
>
> The fix from your host is `?directConnection=true`, which tells the driver "talk to exactly this host, skip topology discovery." You lose automatic failover — which is fine for a demo and wrong for production. Full external replica-set access needs a LoadBalancer per member or split-horizon DNS.
>
> **Demonstrate the failure first.** Connect without `directConnection`, watch it hang and time out, then add the flag and watch it work. Thirty seconds of failure teaches driver topology discovery better than a paragraph.

---

## Part 4 — Three ways in: connect, validate, administer, author

All three clients speak the **MongoDB Wire Protocol** — a binary request/response protocol over TCP carrying BSON. `mongosh`, mongo-express, and PyMongo send the same `find` command on the wire. As in Module 1: **the differences are ergonomics, not capability.**

```mermaid
flowchart LR
    subgraph HOST["Your host"]
        SH["mongosh (local binary)"]
        COMPASS["MongoDB Compass (desktop)"]
        BROWSER["Web browser"]
    end
    subgraph K3S["K3s — namespace mongo-lab"]
        MSH["mongosh inside mongodb-0<br/>(kubectl exec)"]
        ME["mongo-express pod"]
        JUP["JupyterLab pod<br/>PyMongo"]
        HL["Service: mongodb-headless<br/>(per-pod DNS)"]
        NP["Service: mongodb-nodeport:30017"]
        M0[("mongodb-0<br/>PRIMARY")]
        M1[("mongodb-1<br/>SECONDARY")]
        M2[("mongodb-2<br/>SECONDARY")]
    end
    MSH --> M0
    ME --> HL
    JUP --> HL
    HL --> M0
    HL --> M1
    HL --> M2
    NP --> M0
    SH -->|localhost:30017<br/>directConnection=true| NP
    COMPASS -->|localhost:30017| NP
    BROWSER -->|HTTP :30081| ME
    BROWSER -->|HTTP :30089| JUP
```

| Client | Strongest at | Weakest at |
|---|---|---|
| **mongosh** | Diagnostics, replica-set administration, `explain()`, one-off surgery, scripting | Reading large result sets; no rich rendering |
| **mongo-express / Compass** | Exploring an unfamiliar database, visual schema analysis, index recommendations, building aggregations | Automation; anything repeatable or version-controlled |
| **PyMongo** | Application logic, bulk ETL, tests, pandas analysis | Interactive poking |

> **Rule of thumb, unchanged from Module 1: explore in the GUI, diagnose in the shell, ship in Python.**

---

### 4.1 `mongosh`

`mongosh` ships inside the official image, so it is already in the pod. It is a **full JavaScript REPL** with database globals — not a bespoke query language, which means you can write loops, functions, and `JSON.stringify` right in the prompt.

#### Connect

```bash
# --- Path A: one-shot (best for scripts and video) ---
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
  --eval 'db.adminCommand("ping")'

# --- Path B: interactive. Note -it and the -- separator. ---
kubectl -n mongo-lab exec -it mongodb-0 -- mongosh \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin retail

# --- Path C: an ephemeral client pod. THE pattern to teach — it is how you
# --- debug a service you have no shell in, and it exercises in-cluster DNS
# --- plus real replica-set discovery rather than the loopback shortcut.
kubectl -n mongo-lab run mongo-client --rm -it --restart=Never \
  --image=mongo:8.0 -- \
  mongosh "mongodb://retail_app:RetailApp2026!@mongodb-0.mongodb-headless.mongo-lab.svc.cluster.local:27017,mongodb-1.mongodb-headless.mongo-lab.svc.cluster.local:27017,mongodb-2.mongodb-headless.mongo-lab.svc.cluster.local:27017/retail?replicaSet=rs0&authSource=admin"

# --- Path D: from your host. NOTE directConnection — see 3.6. ---
mongosh "mongodb://admin:MongoLab2026!@localhost:30017/?directConnection=true&authSource=admin"
```

**Anatomy of a connection URI** — worth a slide, because every option here is a decision:

```
mongodb://retail_app:RetailApp2026!@host1:27017,host2:27017,host3:27017/retail?replicaSet=rs0&authSource=admin&w=majority&readPreference=primaryPreferred
─────────  ─────────────────────── ─────────────────────────────────── ────── ─────────────────────────────────────────────────────────────────────
scheme     credentials             SEED LIST (not a load balancer —    default  options
                                   the driver learns the real          database
                                   topology from any one of these)

replicaSet=rs0        Enables topology discovery and automatic failover.
                      WITHOUT it the driver treats each host as standalone.
authSource=admin      WHERE the user is defined. Our users live in 'admin'
                      but work on 'retail' — forgetting this is the #1 cause
                      of "Authentication failed" with correct credentials.
w=majority            Write concern: a majority must acknowledge. See 8.4.
readPreference=...    Which member serves reads. See 8.5.
```

**Authentication hygiene:**

| Method | Verdict |
|---|---|
| `-p 'password'` on the command line | **Avoid.** Visible in `ps` and shell history |
| `-p` with no value | **Preferred interactively** — `mongosh` prompts, nothing lands in history |
| Password in the URI | Same exposure as `-p`; fine when the value came from a Secret |
| `--authenticationDatabase admin` | **Always required here**, because the users live in `admin` |

```bash
# The first command to run when a permission error surprises you.
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u retail_app -p 'RetailApp2026!' --authenticationDatabase admin \
  --eval 'db.runCommand({connectionStatus: 1}).authInfo'
```

#### Validate

```javascript
// --- Liveness and identity ---
db.adminCommand("ping")
db.version()
db.hello()                       // topology as the SERVER sees it

// --- Confirm OUR configuration loaded, not the image defaults ---
db.adminCommand({ getParameter: 1, wiredTigerEngineRuntimeConfig: 1 })
db.serverStatus().wiredTiger.cache["maximum bytes configured"]  // expect ~536870912
db.adminCommand({ getCmdLineOpts: 1 }).parsed                   // shows mongod.conf

// --- Replica set health ---
rs.status()                      // full detail: state, uptime, heartbeats, lag
rs.conf()                        // the CONFIG — verify hostnames, not IPs
rs.printReplicationInfo()        // oplog size and time window
rs.printSecondaryReplicationInfo()  // lag per secondary

// --- Storage and memory ---
db.stats()                       // this database: size, count, avg doc size, indexes
db.serverStatus().mem            // resident, virtual
db.serverStatus().connections    // current / available / totalCreated
db.serverStatus().opcounters     // insert/query/update/delete/command since start

// --- Security posture ---
db.getSiblingDB("admin").getUsers()
db.getSiblingDB("admin").getRoles({ showBuiltinRoles: false })

// --- Baseline before we add data ---
db.getSiblingDB("retail").getCollectionNames()
db.getSiblingDB("retail").customers.countDocuments()
```

```bash
# Latency and throughput from the shell.
# There is no 'mongo-benchmark' equivalent to redis-benchmark, so we time it.
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin retail --eval '
  // 1000 sequential round trips
  let t0 = Date.now();
  for (let i = 0; i < 1000; i++) db.adminCommand("ping");
  const seq = Date.now() - t0;

  // 1000 documents in ONE batched insert — the same round-trip lesson as
  // pipelining in Module 1, and it is just as dramatic.
  const docs = Array.from({length: 1000}, (_, i) => ({_id: i, v: "x"}));
  db.bench.drop();
  t0 = Date.now();
  db.bench.insertMany(docs, { ordered: false });
  const batch = Date.now() - t0;

  print(`1000 sequential pings : ${seq} ms`);
  print(`1000 batched inserts  : ${batch} ms  (${(seq/batch).toFixed(1)}x fewer round trips)`);
  db.bench.drop();
'
```

#### Administer

```javascript
// --- Users and roles ---
// Contrast with Module 1: Redis ACLs matched KEY PATTERNS. MongoDB RBAC grants
// a ROLE on a DATABASE. Different granularity, same intent.
db.getSiblingDB("admin").createUser({
  user: "analyst",
  pwd:  passwordPrompt(),                    // prompts — never in history
  roles: [ { role: "read", db: "retail" } ]  // READ ONLY on ONE database
});

// A CUSTOM role — finer-grained than the built-ins, scoped to collections.
db.getSiblingDB("admin").createRole({
  role: "orderReader",
  privileges: [{
    resource: { db: "retail", collection: "orders" },   // ONE collection
    actions:  [ "find" ]
  }],
  roles: []
});

db.getSiblingDB("admin").getUser("analyst")
db.getSiblingDB("admin").grantRolesToUser("analyst", [{role: "orderReader", db: "admin"}])
db.getSiblingDB("admin").dropUser("analyst")
```

```javascript
// --- Connections and current operations ---
db.currentOp({ "secs_running": { $gt: 1 } })   // anything running > 1 second
db.killOp(12345)                                // kill a runaway operation

// --- The PROFILER — MongoDB's slow query log ---
// Our mongod.conf sets mode 'slowOp' at 100 ms. The profiler writes to a
// CAPPED COLLECTION you can query with normal find() — a genuinely nice design.
db.getProfilingStatus()
db.setProfilingLevel(1, { slowms: 50 })         // 0=off, 1=slow only, 2=ALL

db.system.profile.find().sort({ ts: -1 }).limit(5).pretty()
db.system.profile.find({ millis: { $gt: 100 } }).sort({ millis: -1 }).limit(3)

// WARNING: level 2 profiles EVERY operation. It is a debugging tool, never a
// steady state — the same caveat as Redis MONITOR in Module 1.
db.setProfilingLevel(1, { slowms: 100 })        // put it back
```

```javascript
// --- Storage diagnostics ---
db.stats(1024*1024)                             // sizes in MB
db.customers.stats()                            // per-collection detail
db.customers.totalIndexSize()
db.customers.getIndexes()

// Index USAGE — the single most useful maintenance query in MongoDB. An index
// with accesses.ops = 0 after weeks of production is pure write overhead.
db.customers.aggregate([{ $indexStats: {} }]).forEach(i =>
  print(`${i.name.padEnd(30)} ops: ${i.accesses.ops}  since: ${i.accesses.since}`)
);

// --- Compaction. Deleting documents does NOT return disk to the OS. ---
db.runCommand({ compact: "customers" })         // blocks; run on a SECONDARY
```

```javascript
// --- Replica set administration (more in Part 8) ---
rs.status()
rs.conf()
rs.stepDown(60)                                 // force a primary election
rs.add("mongodb-3.mongodb-headless.mongo-lab.svc.cluster.local:27017")
rs.remove("mongodb-3.mongodb-headless.mongo-lab.svc.cluster.local:27017")

// Change a member's priority — reconfigure the SET, not a single node.
cfg = rs.conf();
cfg.members[1].priority = 0;                    // never become primary
rs.reconfig(cfg);
```

> **The Kubernetes twist, same as Module 1.** `rs.reconfig()` and `db.createUser()` change **runtime state that lives in the data directory** — they survive a pod restart because the PVC survives. But `mongod.conf` comes from the ConfigMap, and editing it requires a rollout:
>
> ```bash
> kubectl apply -f k3s/10-mongodb-config.yaml
> # A ConfigMap update does NOT restart anything. mongod parsed the file once.
> kubectl -n mongo-lab rollout restart statefulset/mongodb
> kubectl -n mongo-lab rollout status  statefulset/mongodb --timeout=300s
> ```
>
> A StatefulSet rolls **one pod at a time, highest ordinal first** — so `mongodb-2`, then `-1`, then `-0`. Because `mongodb-0` has priority 2, restarting it triggers an election and a brief write outage. **This is the correct, safe order**, and watching `rs.status()` during a rollout is a great live demo.

#### Author

```javascript
use retail

// --- Insert. MongoDB creates the database AND collection lazily on first
// --- write — there is no CREATE DATABASE and no CREATE TABLE.
db.customers.insertOne({
  _id: "C99999",
  first_name: "Ahmed", last_name: "Sami",
  email: "ahmed@example.com",
  tier: "gold",
  loyalty_points: NumberInt(1200),
  // NESTED — this is the entire point. In Module 1 we flattened this into
  // 'address.city' as a literal Redis hash field name and lost the structure.
  address: { city: "Houston", state: "TX", zip: "77002", country: "US" },
  preferences: { newsletter: true, categories: ["electronics", "books"] },
  signup_date: new Date("2026-08-09")
});

// --- Batched insert. ordered:false keeps going past a failure and is
// --- significantly faster; ordered:true stops at the first error.
db.products.insertMany([
  { _id: "SKU-00001", name: "Laptop Pro",   category: "electronics",
    price: NumberDecimal("1299.00"), stock: NumberInt(42) },
  { _id: "SKU-00002", name: "Yoga Mat X",   category: "sports",
    price: NumberDecimal("89.50"),   stock: NumberInt(150) }
], { ordered: false });

// --- Nested arrays of sub-documents: the shape a document store exists for.
db.orders.insertOne({
  _id: "O000001",
  customer_id: "C99999",
  order_ts: new Date("2026-02-14T09:41:22Z"),
  status: "shipped",
  items: [
    { sku: "SKU-00001", name: "Laptop Pro", qty: NumberInt(1),
      unit_price: NumberDecimal("1299.00"), line_total: NumberDecimal("1299.00") },
    { sku: "SKU-00002", name: "Yoga Mat X", qty: NumberInt(2),
      unit_price: NumberDecimal("89.50"),   line_total: NumberDecimal("179.00") }
  ],
  total: NumberDecimal("1478.00"),
  ship_to: { city: "Houston", state: "TX", zip: "77002" }
});
```

```javascript
// --- Loading a file. mongoimport is the bulk tool; from the shell, load().
// mongoimport --uri "mongodb://..." --collection customers --file customers.json --jsonArray

// --- Scripting: mongosh is real JavaScript, so this just works.
for (let i = 1; i <= 100; i++) {
  db.bulk_demo.insertOne({ _id: i, squared: i * i, bucket: i % 10 });
}
db.bulk_demo.countDocuments()
db.bulk_demo.drop()
```

---

### 4.2 mongo-express and Compass

#### Connect — mongo-express

Open `http://localhost:30081`. Basic auth: `admin` / `MongoLab2026!`.

It connects automatically using `ME_CONFIG_MONGODB_URL` from the manifest — a full replica-set URI, so it follows a primary election rather than breaking on one.

#### Connect — Compass (the better tool)

Compass is a desktop app, so it runs on your **host** and must use `directConnection`:

```
mongodb://admin:MongoLab2026!@localhost:30017/?directConnection=true&authSource=admin
```

| Field | Value | Why |
|---|---|---|
| Host | `localhost` | Compass runs on your host, not in the cluster |
| Port | `30017` | The **NodePort**, not 27017 |
| `directConnection` | **`true`** | **Required.** Otherwise Compass discovers in-cluster DNS names it cannot resolve, and hangs |
| `authSource` | `admin` | Where the user is defined |

> **Deliberately fail first**, as in Module 1. Connect without `directConnection=true` and watch it hang, then time out with a server-selection error. That failure *is* the driver topology-discovery lesson.

#### Validate

| Where | What it tells you |
|---|---|
| **Database list** | `admin`, `config`, `local`, `retail`. `local` holds the **oplog** — Part 8 |
| **Collection view** | Documents rendered as expandable trees. Nesting becomes visually obvious |
| **Compass → Schema tab** | **Samples the collection and infers the schema** — field frequencies, type distributions, value histograms. There is no CLI equivalent, and it is the single best reason to use Compass |
| **Compass → Explain Plan** | A visual `explain()`: stages, documents examined vs returned, index used |
| **Compass → Indexes tab** | Existing indexes, size, and **usage counts** — find the dead ones |
| **Compass → Performance tab** | Live ops/sec, network, slow operations |

Three checks mapping one-to-one onto 4.1: the database list matches `show dbs`; a collection's document count matches `countDocuments()`; the Indexes tab matches `getIndexes()`.

> **Compass's Schema tab is the killer feature for a document store**, and it is worth dwelling on. In a schema-on-read system, **nobody knows what shape the data actually is** — that's §1.4's silent-failure problem. The Schema tab answers it empirically: *87% of documents have `loyalty_points` as `Int32`, 13% as `String`.* That's a data-quality bug you would otherwise find in a wrong dashboard three months later.

#### Administer

Both GUIs can create/drop databases, collections, and indexes; import/export JSON and CSV; and Compass can manage validation rules visually.

| Feature | Caveat |
|---|---|
| Create/drop collection | Trivially easy, and irreversible |
| **Create index** | Compass builds it in the **foreground by default in the UI** — on a large collection that blocks. Prefer `createIndex` from the shell with an eye on `currentOp` |
| Import JSON/CSV | Fine for small files. Use `mongoimport` past a few MB |
| **Schema analysis** | **Sampled**, not exhaustive — an estimate, not an audit |
| Aggregation builder | Genuinely excellent: build a pipeline stage by stage with live previews, then **export to Python** |

> **The limit, stated plainly:** neither GUI can change your Kubernetes manifests. Anything you do is runtime state — it survives on the PVC, but `mongod.conf` changes still need a ConfigMap edit and a rollout.

#### Author

Both let you insert and edit documents in a JSON editor with BSON type awareness. Two things worth demonstrating on camera:

- **Edit a nested field in place.** Compass issues `{$set: {"address.city": "Austin"}}` — it does **not** read, mutate, and rewrite the whole document. That's exactly the discipline §6.4 teaches in code.
- **The Aggregation Builder → Export to language.** Build a pipeline visually, then export it as PyMongo code and paste it into a notebook. It is the fastest way to learn the aggregation framework, and it directly bridges §4.2 to §4.3.

---

### 4.3 PyMongo in JupyterLab

Open `http://localhost:30089/lab?token=mongo-lab`.

**The Python library landscape:**

| Library | Layer | Use it for | Notes |
|---|---|---|---|
| **PyMongo** (`pip install pymongo`) | Official driver | Everything. The baseline | Maintained by MongoDB Inc. |
| **Motor** | Async driver | asyncio applications | Same API, awaited. Being folded into PyMongo's own async support |
| **MongoEngine** | ODM | Django-style declarative documents | Adds a schema layer *on top of* a schemaless store — decide deliberately |
| **Beanie** | Async ODM | Pydantic models over Motor | The modern FastAPI pairing |
| **`pandas` + `pymongoarrow`** | Analytics | Aggregation results straight into a DataFrame or Arrow table | Much faster than `list(cursor)` for large results |

We use **PyMongo directly**, because the point is to see the commands.

#### Connect

```python
# ---------------------------------------------------------------------------
# MongoClient is a CONNECTION POOL and it is THREAD-SAFE. Create ONE per
# process and share it. Creating a client per request is a classic
# performance bug — you pay TCP handshake, TLS, auth, AND topology discovery
# every single time.
#
# The client also runs a BACKGROUND MONITOR thread per server, tracking who is
# primary. That is what makes automatic failover work — and another reason not
# to create clients casually.
# ---------------------------------------------------------------------------
import os
from pymongo import MongoClient, ASCENDING, DESCENDING
from pymongo.errors import (
    ConnectionFailure, OperationFailure, ServerSelectionTimeoutError,
    DuplicateKeyError, BulkWriteError,
)

# Injected by the manifest. The fallback lets the SAME notebook run on your
# host against a port-forward.
MONGODB_URI = os.getenv(
    "MONGODB_URI",
    "mongodb://retail_app:RetailApp2026!@localhost:27017/retail"
    "?authSource=admin&directConnection=true",
)

client = MongoClient(
    MONGODB_URI,
    # --- Timeouts: the three that actually matter ---
    serverSelectionTimeoutMS=5000,   # how long to hunt for a suitable server.
                                     # This is what fires when the replica set
                                     # has no primary — NOT a connection error.
    connectTimeoutMS=5000,           # TCP handshake
    socketTimeoutMS=30000,           # a single operation's read
    # --- Pooling ---
    maxPoolSize=50,                  # per-server upper bound
    minPoolSize=5,                   # keep warm, avoid handshake on burst
    maxIdleTimeMS=60000,
    # --- Correctness defaults, set ONCE here rather than per call ---
    retryWrites=True,                # retry a write ONCE after a failover.
                                     # Safe because the driver attaches a
                                     # transaction id, so it cannot double-apply
    retryReads=True,
    appname="jupyter-mongo-lab",     # shows up in db.currentOp() and the logs —
                                     # do this ALWAYS, it makes triage possible
)

db = client[os.getenv("MONGODB_DATABASE", "retail")]

try:
    # 'ping' forces the driver to actually complete server selection. Simply
    # constructing MongoClient does NOT connect — it is lazy, which surprises
    # people who expect a bad URI to fail immediately.
    client.admin.command("ping")
    print("Connected.")
    print("  Topology :", client.topology_description.topology_type_name)
    print("  Primary  :", client.primary)
    print("  Secondary:", client.secondaries)
    print("  Database :", db.name)
except ServerSelectionTimeoutError as e:
    print(f"No suitable server within 5s: {e}\n"
          f"Inside the cluster use the mongodb-N.mongodb-headless... seeds; "
          f"from your laptop use localhost with directConnection=true.")
except OperationFailure as e:
    print(f"Auth failed: {e}\nCheck authSource=admin — the users live in 'admin'.")
```

```python
# ---------------------------------------------------------------------------
# Read/write concern and read preference can be set at FOUR levels, each
# overriding the one above: client -> database -> collection -> operation.
# Setting them per collection is usually the right granularity.
# ---------------------------------------------------------------------------
from pymongo import ReadPreference
from pymongo.write_concern import WriteConcern
from pymongo.read_concern import ReadConcern

# A collection handle for money: majority-acknowledged writes, majority reads.
orders_safe = db.get_collection(
    "orders",
    write_concern=WriteConcern(w="majority", wtimeout=5000, j=True),
    read_concern=ReadConcern("majority"),
    read_preference=ReadPreference.PRIMARY,
)

# A collection handle for a dashboard: stale reads are fine, spread the load.
orders_fast = db.get_collection(
    "orders",
    read_preference=ReadPreference.SECONDARY_PREFERRED,
    read_concern=ReadConcern("local"),
)
# Same collection, two contracts. This is Part 8 in one cell.
```

#### Validate

```python
# ---------------------------------------------------------------------------
# The same checks as mongosh, but as Python objects we can ASSERT against.
# Asserting beats eyeballing: a silently ignored config looks fine in a print.
# ---------------------------------------------------------------------------
import pandas as pd

status = client.admin.command("replSetGetStatus")
print(f"Replica set: {status['set']}")
display(pd.DataFrame([{
    "member":  m["name"].split(".")[0],
    "state":   m["stateStr"],
    "health":  m["health"],
    "uptime_s": m.get("uptime"),
    "lag_s":   (status["date"] - m["optimeDate"]).total_seconds()
               if m["stateStr"] == "SECONDARY" else 0,
} for m in status["members"]]))

srv = client.admin.command("serverStatus")
summary = {
    "MongoDB version":   srv["version"],
    "Uptime (s)":        srv["uptime"],
    "Current conns":     srv["connections"]["current"],
    "Available conns":   srv["connections"]["available"],
    "Resident MB":       srv["mem"]["resident"],
    "WT cache max MB":   srv["wiredTiger"]["cache"]["maximum bytes configured"] // 1024**2,
    "WT cache used MB":  srv["wiredTiger"]["cache"]["bytes currently in the cache"] // 1024**2,
}
display(pd.DataFrame(summary.items(), columns=["Metric", "Value"]))

# Assert our ConfigMap actually applied — catches a mis-mounted config, which
# otherwise only shows up as "why is it OOMKilling?" an hour later.
assert srv["wiredTiger"]["cache"]["maximum bytes configured"] <= 600 * 1024**2, \
    "WiredTiger cache is larger than mongod.conf specifies — ConfigMap not applied!"
assert status["set"] == "rs0"
assert any(m["stateStr"] == "PRIMARY" for m in status["members"]), "No primary!"
print("\nConfiguration confirmed.")
```

```python
# ---------------------------------------------------------------------------
# Round trips: the same lesson as pipelining in Module 1, and just as dramatic.
# ---------------------------------------------------------------------------
import time
db.bench.drop()

t0 = time.perf_counter()
for i in range(1000):
    db.bench.insert_one({"_id": i, "v": "x"})       # 1000 round trips
seq_ms = (time.perf_counter() - t0) * 1000

db.bench.drop()
t0 = time.perf_counter()
db.bench.insert_many([{"_id": i, "v": "x"} for i in range(1000)], ordered=False)
batch_ms = (time.perf_counter() - t0) * 1000

print(f"1000 insert_one : {seq_ms:8.1f} ms")
print(f"1 insert_many   : {batch_ms:8.1f} ms  ({seq_ms/batch_ms:.1f}x faster)")
db.bench.drop()
```

#### Administer

```python
# --- A reusable health report — the deliverable worth keeping. -------------
def health_report(client: MongoClient, dbname="retail") -> pd.DataFrame:
    """Single-screen operational summary with pass/warn verdicts."""
    srv    = client.admin.command("serverStatus")
    rs     = client.admin.command("replSetGetStatus")
    dbst   = client[dbname].command("dbStats")
    prim   = [m for m in rs["members"] if m["stateStr"] == "PRIMARY"]
    lags   = [(rs["date"] - m["optimeDate"]).total_seconds()
              for m in rs["members"] if m["stateStr"] == "SECONDARY"]
    maxlag = max(lags) if lags else 0
    conns  = srv["connections"]
    cache  = srv["wiredTiger"]["cache"]
    cache_pct = cache["bytes currently in the cache"] / \
                cache["maximum bytes configured"] * 100
    conn_pct  = conns["current"] / (conns["current"] + conns["available"]) * 100

    rows = [
        ("Ping",            "ok",                            "OK"),
        ("Replica set",     rs["set"],                       "OK"),
        ("Primary",         prim[0]["name"].split(".")[0] if prim else "NONE",
                            "OK" if prim else "FAIL"),
        ("Members healthy", f"{sum(m['health'] for m in rs['members']):.0f}/"
                            f"{len(rs['members'])}",
                            "OK" if all(m["health"] == 1 for m in rs["members"]) else "FAIL"),
        ("Max replica lag", f"{maxlag:.1f}s",  "OK" if maxlag < 10 else "WARN"),
        ("WT cache used",   f"{cache_pct:.1f}%", "OK" if cache_pct < 80 else "WARN"),
        ("Connections",     f"{conns['current']} ({conn_pct:.1f}%)",
                            "OK" if conn_pct < 80 else "WARN"),
        ("Data size",       f"{dbst['dataSize']/1024**2:.1f} MB",  "OK"),
        ("Index size",      f"{dbst['indexSize']/1024**2:.1f} MB", "OK"),
        ("Collections",     dbst["collections"],              "OK"),
        ("Objects",         f"{dbst['objects']:,}",           "OK"),
    ]
    return pd.DataFrame(rows, columns=["Check", "Value", "Verdict"])

display(health_report(client))
```

```python
# --- Index inventory and usage. Dead indexes are pure write overhead. ------
def index_report(db, collection: str) -> pd.DataFrame:
    stats = {s["name"]: s for s in db[collection].aggregate([{"$indexStats": {}}])}
    rows = []
    for idx in db[collection].list_indexes():
        name = idx["name"]
        rows.append({
            "index":  name,
            "keys":   dict(idx["key"]),
            "unique": idx.get("unique", False),
            "sparse": idx.get("sparse", False),
            "ttl_s":  idx.get("expireAfterSeconds"),
            "ops":    stats.get(name, {}).get("accesses", {}).get("ops", 0),
        })
    return pd.DataFrame(rows)

display(index_report(db, "customers"))

# --- Slow operations, from the profiler collection ------------------------
slow = list(db.system.profile.find({"millis": {"$gt": 50}})
                             .sort("ts", -1).limit(10))
if slow:
    display(pd.DataFrame([{
        "ts": s["ts"], "ms": s["millis"], "op": s["op"],
        "ns": s["ns"], "docsExamined": s.get("docsExamined"),
        "nreturned": s.get("nreturned"), "plan": s.get("planSummary"),
    } for s in slow]))

# --- The escape hatch: any command PyMongo has no helper for ---------------
print(client.admin.command("buildInfo")["version"])
print(client.admin.command({"getParameter": 1, "featureCompatibilityVersion": 1}))
```

#### Author

```python
# ---------------------------------------------------------------------------
# One document of every BSON type that matters, so the type system is concrete
# before Part 5.
# ---------------------------------------------------------------------------
from bson import ObjectId, Decimal128, Binary, Int64
from datetime import datetime, timezone
from decimal import Decimal

db.types_demo.delete_many({})
db.types_demo.insert_one({
    "_id":       ObjectId(),                       # 12 bytes, timestamp-sortable
    "an_int":    42,                               # -> int32 automatically
    "a_long":    Int64(9007199254740993),          # beyond double's exact range
    "a_double":  3.14159,                          # DO NOT use for money
    "money":     Decimal128(Decimal("249.99")),    # EXACT. Use for money.
    "when":      datetime.now(timezone.utc),       # native Date, not a string
    "blob":      Binary(b"\x00\x01\x02"),
    "nested":    {"a": {"b": {"c": "arbitrary depth"}}},
    "array":     [1, 2, 3],
    "docs":      [{"sku": "A", "qty": 1}, {"sku": "B", "qty": 2}],
    "nothing":   None,                             # null is a VALUE...
    # ...and an ABSENT field is different. See 6.3 — this trips people up.
})

doc = db.types_demo.find_one()
for k, v in doc.items():
    print(f"  {k:<10} {type(v).__name__:<12} {v!r}"[:100])
```

```python
# ---------------------------------------------------------------------------
# bulk_write: heterogeneous operations in ONE round trip. This is the PyMongo
# equivalent of a Redis pipeline, and it is the single highest-leverage
# performance idiom in the driver.
# ---------------------------------------------------------------------------
from pymongo import InsertOne, UpdateOne, DeleteOne, ReplaceOne

result = db.bulk_demo.bulk_write([
    InsertOne({"_id": 1, "v": "a"}),
    InsertOne({"_id": 2, "v": "b"}),
    UpdateOne({"_id": 1}, {"$set": {"v": "updated"}}),
    ReplaceOne({"_id": 2}, {"_id": 2, "v": "replaced", "extra": True}),
    DeleteOne({"_id": 999}),                      # no-op, no error
], ordered=False)   # ordered=False continues past failures AND parallelises

print(f"inserted={result.inserted_count} modified={result.modified_count} "
      f"deleted={result.deleted_count}")
db.bulk_demo.drop()
```

---

### 4.4 Capability matrix

| Task | mongosh | Compass / mongo-express | PyMongo |
|---|---|---|---|
| Quick liveness check | **Best** — one line | Yes | Yes |
| Explore an unfamiliar database | Workable | **Best** — tree view, schema inference | Workable |
| **Infer the actual schema** | No native equivalent | **Best — Compass Schema tab** | Possible via aggregation |
| Read `explain()` output | Good | **Best** — visual plan | Good |
| Replica set administration | **Best** — `rs.*` helpers | Read-only | Via `admin.command` |
| Build an aggregation pipeline | Workable | **Best** — live previews + export to Python | Best once you know it |
| Bulk data load | `mongoimport` | Small files only | **Best** — `bulk_write` |
| Repeatable, version-controlled work | Good (`.js` files) | No | **Best** |
| Application logic | No | No | **Best** |
| Runs where there is no GUI | **Best** | No | Yes |
| **Change durable configuration** | **No — ConfigMap + rollout** | **No** | **No** |

> **The exercise that ties the part together.** One task, all three clients:
>
> *Insert a customer `C77777` with a nested `address` and a `preferences.categories` array; create an index on `tier`; then verify from a **different** client that the document exists, that `address.city` is queryable, that the array matches `$in`, and that the index appears in `getIndexes()`.*
>
> Getting the identical answer three times converts "MongoDB has clients" into "MongoDB has one wire protocol and several front ends."

---

## Part 5 — The mental model: MongoDB's object hierarchy

Everyone arriving from SQL carries *server → database → schema → table → row → column*. MongoDB's hierarchy maps onto this **much more closely than Redis's did** — which is good news, and also a trap, because the two levels that look identical behave differently in one crucial respect.

State the rule first:

> **MongoDB's container hierarchy looks like SQL's, but the schema lives in the document, not in the container.** A table declares its columns; a collection declares nothing. Two documents in one collection can share not a single field name.

### 5.1 The whole hierarchy on one page

```mermaid
flowchart TB
    subgraph L1["Level 1 — DEPLOYMENT (standalone / replica set / sharded cluster) — Part 8"]
        subgraph L2["Level 2 — SERVER INSTANCE (one mongod, one port, one dbPath, one WT cache)"]
            direction TB
            SRV["Instance-scoped:<br/>users &amp; roles (in admin) · connections · profiler<br/>oplog (in local) · WiredTiger cache · config"]
            subgraph L3["Level 3 — DATABASE (named, created lazily, IS a real boundary)"]
                subgraph L4["Level 4 — COLLECTION (named, schemaless by default, opt-in validation)"]
                    subgraph L5["Level 5 — DOCUMENT (BSON, ≤16 MB, unique immutable _id)"]
                        subgraph L6["Level 6 — FIELD (typed per document, not per collection)"]
                            L7["Level 7 — NESTED VALUES<br/>sub-documents · arrays · arrays of sub-documents<br/>arbitrary depth (100 levels max)"]
                        end
                    end
                end
                IDX["INDEXES — per collection, engine-maintained"]
                VIEWS["VIEWS — read-only, defined by a pipeline"]
            end
        end
    end
```

```
DEPLOYMENT              standalone | replica set | sharded cluster
└── SERVER INSTANCE     one mongod · one port · one dbPath · one WT cache
    ├── (instance-scoped)   users/roles · connections · profiler · oplog
    └── DATABASE            named · created lazily · a REAL security boundary
        ├── COLLECTION      named · schemaless by default · opt-in validation
        │   └── DOCUMENT    BSON · <= 16 MB · unique, immutable _id
        │       └── FIELD   typed PER DOCUMENT
        │           └── NESTED  sub-docs, arrays, arrays of sub-docs
        ├── INDEXES         per collection, engine-maintained
        └── VIEWS           read-only, defined by an aggregation pipeline
```

**Three observations that make everything else follow:**

- **A database is a real boundary here** — unlike Redis's numbered databases (Module 1, §5.3), which were a namespace with no isolation of any kind. A MongoDB database is a **security boundary** (roles are granted per database), a **namespace boundary**, and historically a **locking boundary**. That's a genuine upgrade.
- **A collection is not a table.** It has a name and it holds documents. It does *not* declare columns, types, or constraints — unless you opt in with a validator (§7.6).
- **The type system lives at the field, per document.** In SQL a column is typed and every row obeys it. In MongoDB, `loyalty_points` can be `Int32` in one document and `String` in the next, in the same collection, with nothing complaining.

### 5.2 Level 2 — the server instance

One `mongod`: one process, one port, one `dbPath`, one WiredTiger cache, one config file, one identity for monitoring. In our lab each instance maps one-to-one onto a pod (`mongodb-0`, `-1`, `-2`) — which is why we used a StatefulSet.

```javascript
db.serverStatus()                      // the big one: everything below, at once
db.serverStatus().connections          // current / available / totalCreated
db.serverStatus().mem                  // resident / virtual
db.serverStatus().wiredTiger.cache     // cache pressure — the number to watch
db.serverStatus().opcounters           // insert/query/update/delete since start
db.serverStatus().repl                 // this member's replication view
db.adminCommand({ getCmdLineOpts: 1 }) // proves WHICH config file was parsed
db.hostInfo()                          // OS, cores, RAM as mongod sees them
```

**Three system databases exist on every instance**, and knowing what's in them is genuinely useful:

| Database | Contains | Why you care |
|---|---|---|
| **`admin`** | Users, roles, cluster-wide commands | Your users live here. `authSource=admin` in every URI |
| **`local`** | **The oplog** (`local.oplog.rs`), startup log, replica-set state | **Never replicated.** Part 8 reads the oplog directly |
| **`config`** | Sharding metadata (chunks, shards, balancer state) | Empty until you shard. §8.6 |

```javascript
// The oplog is a COLLECTION. You can query it. This is a great demo.
db.getSiblingDB("local").oplog.rs.find().sort({$natural: -1}).limit(3)
db.getSiblingDB("local").oplog.rs.stats().maxSize / 1024 / 1024   // MB
```

### 5.3 Level 3 — the database

| Property | Reality |
|---|---|
| **Identity** | A name. Max 64 chars; no `/ \ . " $ * < > : \| ?` |
| **Creation** | **Lazy.** `use retail` creates nothing; the first insert does |
| **Deletion** | `db.dropDatabase()` — real, immediate, irreversible |
| **Security** | **A real boundary.** Roles are granted per database: `{role: "readWrite", db: "retail"}` |
| **Isolation** | Namespace + security, **but not resources** — one WiredTiger cache and one disk serve all databases on the instance |
| **Selection** | `use <db>` in the shell; `client["retail"]` in a driver. Per-connection |
| **Contents** | Collections, views, and indexes |

```javascript
show dbs                    // ONLY non-empty databases appear — same as Redis
use retail                  // creates nothing
db.getName()
db.stats(1024*1024)         // sizes in MB
db.getCollectionNames()
db.getCollectionInfos()     // includes type: collection vs view, and options
```

> **The contrast with Module 1 is worth a slide.** Redis databases were numbered 0–15, pre-allocated, with no security, persistence, or replication isolation — a namespace and nothing more, which their creator publicly regretted. MongoDB databases are **named, created on demand, and are a genuine RBAC boundary.** But they still share one storage engine and one cache, so **resource isolation still means separate instances.** Half the lesson carries over.

### 5.4 Level 4 — the collection

A named container for documents. Compared with a SQL table, here is what it does **not** have by default: a column list, column types, `NOT NULL`, `CHECK` constraints, foreign keys, or a fixed row shape.

Here is what it **does** have: a name, an `_id` index it creates for you and you cannot drop, any other indexes you create, optional **validation rules**, and optional special behaviours.

| Collection type | What it is | Use for |
|---|---|---|
| **Standard** | The default | Everything |
| **Capped** | Fixed size, insertion-ordered, auto-overwrites oldest | The oplog itself; high-volume logs. **Cannot delete or grow documents** |
| **Time series** (5.0+) | Columnar-ish storage optimised for `timestamp` + `metadata` | Metrics, IoT. Dramatically better compression |
| **Clustered** (5.3+) | Documents stored *in* the `_id` index B-tree | Point lookups by `_id`; saves one index |
| **View** | Read-only, defined by an aggregation pipeline | Hiding fields, pre-filtering. Materialised via `$merge` |

```javascript
// Standard — implicit creation on first insert
db.customers.insertOne({_id: "C1", name: "Ava"})

// Explicit creation, with options
db.createCollection("audit_log", { capped: true, size: 10485760, max: 5000 })

db.createCollection("metrics", {
  timeseries: { timeField: "ts", metaField: "sensor", granularity: "seconds" },
  expireAfterSeconds: 2592000        // 30-day retention, built in
})

// A VIEW — the closest MongoDB gets to a SQL view. Read-only, computed on
// every read, and it CAN use the underlying collection's indexes.
db.createView("gold_customers", "customers", [
  { $match: { tier: "gold" } },
  { $project: { email: 0 } }         // hide PII from this view's consumers
])

db.getCollectionInfos({ name: "customers" })
db.customers.stats()
db.customers.drop()
```

### 5.5 Level 5 — the document

| Property | Detail |
|---|---|
| **Format** | BSON — binary, typed, length-prefixed |
| **Max size** | **16 MB.** A hard limit, and the aggregate boundary from Module 1 made concrete |
| **Max nesting** | 100 levels |
| **`_id`** | **Required, unique per collection, immutable, always indexed.** Auto-generated as `ObjectId` if omitted |
| **Field order** | **Preserved** as inserted — which matters, because `{a:1, b:2}` and `{b:2, a:1}` are different for exact-match subdocument queries |
| **Atomicity** | **A single-document write is always atomic**, no matter how deeply nested |
| **Field names** | Cannot start with `$`; `.` and `$` restricted (relaxed in 5.0+, still avoid them) |

**The 16 MB limit and what to do about it** — the same lesson as Redis's unbounded-array trap, in a different costume:

```javascript
// ANTI-PATTERN: an unbounded array inside a document.
// Every append rewrites the whole document, write latency climbs with history
// length, and eventually you hit 16 MB and writes simply fail.
{ _id: "C00001", name: "Ava", orders: [ /* ...50,000 orders... */ ] }

// FIX 1 — REFERENCE. The orders live in their own collection.
{ _id: "C00001", name: "Ava" }
{ _id: "O000001", customer_id: "C00001", total: NumberDecimal("1478.00") }

// FIX 2 — BUCKETING. Bounded chunks with the range encoded in the key.
{ _id: "C00001:2026-Q1", customer_id: "C00001", period: "2026-Q1",
  orders: [ /* ...bounded... */ ], count: 47 }

// FIX 3 — GridFS, for genuinely large binary payloads. Splits a file into
// 255 KB chunks across two collections. For files, not for arrays.
```

> **The modelling question that replaces "normalise or not": embed or reference?**
>
> **Embed** when the child is owned by the parent, read with it, and bounded — order line items, an address. One read, atomic updates, no joins.
>
> **Reference** when the child is shared, large, unbounded, or independently queried — a product referenced by 10,000 orders. Costs a second query or a `$lookup`.
>
> This is Module 1's §2.8 decision tree verbatim; only the mechanics changed.

### 5.6 Level 6 & 7 — fields and nested values

```javascript
{
  _id: "C00001",                          // Level 5: the document
  first_name: "Ava",                      // Level 6: a scalar field
  loyalty_points: NumberInt(12400),
  address: {                              // Level 7: a SUB-DOCUMENT
    city: "Houston",                      //   queried as "address.city"
    state: "TX",
    geo: { type: "Point", coordinates: [-95.37, 29.76] }   // deeper nesting
  },
  tags: ["vip", "newsletter"],            // Level 7: an ARRAY of scalars
  orders: [                               // Level 7: an ARRAY OF SUB-DOCUMENTS
    { sku: "SKU-1", qty: 2 },             //   queried as "orders.sku"
    { sku: "SKU-2", qty: 1 }              //   or "orders" with $elemMatch
  ]
}
```

**Dot notation is the whole interface to nesting**, and it works identically in queries, projections, updates, sorts, and index definitions:

```javascript
db.customers.find({ "address.city": "Houston" })          // query nested
db.customers.find({}, { "address.city": 1 })              // project nested
db.customers.updateOne({}, { $set: { "address.city": "Austin" } })  // update nested
db.customers.createIndex({ "address.city": 1 })           // index nested
db.customers.find().sort({ "address.city": 1 })           // sort nested
```

**Arrays are where MongoDB gets genuinely clever, and genuinely surprising.**

```javascript
// An index on an array field is a MULTIKEY index: MongoDB creates one index
// entry PER ARRAY ELEMENT. This is what makes array queries fast — and it is
// why an index on a 1000-element array costs 1000 index entries per document.
db.customers.createIndex({ tags: 1 })       // multikey, automatically

// Querying an array field matches if ANY element matches. This surprises
// everyone the first time.
db.customers.find({ tags: "vip" })          // matches ["vip","newsletter"]
db.customers.find({ "orders.sku": "SKU-1" })// matches if ANY order has that sku

// THE TRAP: separate conditions can be satisfied by DIFFERENT elements.
db.orders.find({ "items.sku": "SKU-1", "items.qty": { $gt: 5 } })
// ^ matches a document where item A has sku SKU-1 and item B has qty 6.
//   Almost certainly NOT what you meant.

// $elemMatch requires ONE SINGLE element to satisfy ALL conditions.
db.orders.find({ items: { $elemMatch: { sku: "SKU-1", qty: { $gt: 5 } } } })
// ^ this is what you meant.
```

> **`$elemMatch` versus dotted conditions is the single most common correctness bug in MongoDB queries.** It produces a wrong answer, not an error. Demonstrate it with a two-document example on camera.

### 5.7 What is *not* in the hierarchy

| Object | Actual scope | Consequence |
|---|---|---|
| **Users and roles** | **Instance** (stored in `admin`) | A user is defined once and granted roles **per database** |
| **The oplog** | **Instance** (in `local`) | One oplog covers every database. No per-database replication |
| **Connections / `currentOp`** | Instance | `db.currentOp()` shows operations across all databases |
| **The profiler** | **Per database** (`<db>.system.profile`) | A rare per-database thing — unlike Redis, where slowlog was instance-wide |
| **WiredTiger cache** | Instance | **No per-database memory isolation.** Same lesson as Module 1 |
| **Configuration** | Instance | One `mongod.conf` for every database |
| **Change streams** | Collection, database, **or** deployment | The only construct that spans all three levels deliberately |
| **Sharding metadata** | **Cluster** (in `config`) | Sharding is enabled per database, then per collection |

### 5.8 Relational vocabulary → MongoDB vocabulary

| Relational concept | MongoDB equivalent | Honest assessment |
|---|---|---|
| Server / instance | `mongod` instance | Maps 1:1 |
| Database | Database | **Maps closely** — a real namespace and security boundary |
| Schema (Postgres/Oracle sense) | *(nothing)* | Use a separate database, or a collection-name prefix |
| **Table** | **Collection** | Same role, but **declares no structure** |
| **Row** | **Document** | A document is a row **plus its child tables**, nested |
| Column | Field | **Typed per document**, not per collection |
| Column data type | BSON type per field | Nothing enforces consistency without a validator |
| `NULL` | `null` **or an absent field** | **These are different.** A real trap — see §6.3 |
| Primary key | `_id` | Always present, always indexed, immutable |
| **Secondary index** | **Index — engine-maintained** | **The big win over Module 1's Redis**, where you built them by hand |
| Composite index | Compound index | **Prefix rule applies** — order matters. See §7.1 |
| Foreign key | A field holding another `_id` | **No enforcement, no cascade.** Your application's job |
| **JOIN** | `$lookup`, or embed instead | Left-outer-join only; weaker than a planner. **Prefer embedding** |
| `WHERE` | `find(<filter>)` / `$match` | Comparable expressiveness |
| `ORDER BY` | `.sort()` / `$sort` | Sorts **at read**, unlike a Redis Sorted Set which sorts on write |
| `GROUP BY` | `$group` | The aggregation pipeline |
| `HAVING` | `$match` **after** `$group` | Stage order is the semantics |
| Window functions | `$setWindowFields` (5.0+) | Real, and genuinely capable |
| `COUNT(DISTINCT)` | `$group` by the field, then `$count` | Exact. No HyperLogLog needed |
| `AUTO_INCREMENT` | `ObjectId`, or a counter document + `$inc` | `ObjectId` is monotonic — **a bad shard key** |
| Unique constraint | Unique index | Real, engine-enforced |
| `CHECK` constraint | **JSON Schema validator** | Opt-in, per collection. §7.6 |
| **Transaction** | Multi-document transaction | **Real ACID**, requires a replica set, **designed to be rare** |
| View | View | Read-only, pipeline-defined |
| Stored procedure | *(nothing)* | Server-side JS is deprecated. Put logic in the application |
| Trigger | **Change streams** | Asynchronous and external, not in-transaction |
| Materialised view | `$merge` / `$out` into a collection | You schedule the refresh |
| `TRUNCATE TABLE` | `deleteMany({})` or `drop()` | `drop()` is far faster and removes indexes too |
| `DROP DATABASE` | `db.dropDatabase()` | Real |

### 5.9 The eight rules that fall out of the hierarchy

1. **The document is the unit of atomicity.** A single-document write is always atomic, however deeply nested. Multi-document atomicity exists but should be rare.
2. **A collection declares nothing.** Structure lives in the document and in your application — unless you opt into a validator.
3. **`_id` is mandatory, unique, immutable, and indexed.** You cannot drop that index, and you cannot change the value.
4. **16 MB is a hard ceiling.** Unbounded arrays are the #1 modelling failure. Bucket or reference.
5. **Embed for locality; reference for sharing and unboundedness.** This is the modelling decision, and it is made per relationship, not per database.
6. **The engine maintains your indexes — but only the ones you create.** Every index speeds reads and slows writes; audit with `$indexStats`.
7. **A database is a security boundary but not a resource boundary.** One WiredTiger cache serves every database on the instance.
8. **Arrays match if *any* element matches.** Use `$elemMatch` when conditions must be satisfied by the *same* element.

---

## Part 6 — CRUD

We use the **same retail dataset as Module 1**, so the contrast between the two modellings is visible. Everything below is done three times: `mongosh`, then the GUI, then PyMongo.

### 6.1 Loading the dataset

```python
# ---------------------------------------------------------------------------
# generate_and_load.py — run once in a notebook.
#
# THE HEADLINE CONTRAST WITH MODULE 1: there is no flatten() function here.
# In Redis we recursively flattened nested dicts into dotted hash-field names
# and joined lists with '|', because a Redis hash is strictly one level deep.
# Here we insert the dict AS IS. That difference is the entire module.
# ---------------------------------------------------------------------------
import json, random, os
from datetime import datetime, timedelta, timezone
from bson import Decimal128
from decimal import Decimal

random.seed(42)                       # identical data for every student
N_CUSTOMERS, N_PRODUCTS, N_ORDERS, N_EVENTS = 500, 200, 2000, 5000

FIRST = ["Ava","Liam","Noah","Emma","Olivia","Ethan","Mia","Lucas","Zoe","Omar",
         "Sofia","Yusuf","Priya","Chen","Diego","Fatima","Hana","Ivan","Jade","Kofi"]
LAST  = ["Nguyen","Patel","Garcia","Smith","Kim","Okafor","Rossi","Haddad","Silva",
         "Johansson","Ali","Cohen","Dubois","Ivanov","Tanaka","Mensah","Novak","Reyes"]
CITIES = [("Houston","TX"),("Austin","TX"),("Dallas","TX"),("Seattle","WA"),
          ("Chicago","IL"),("Miami","FL"),("Denver","CO"),("Boston","MA")]
CATEGORIES = {
    "electronics": ["Laptop","Headphones","Monitor","Keyboard","Webcam","Tablet"],
    "home":        ["Blender","Lamp","Rug","Cookware Set","Vacuum","Air Fryer"],
    "apparel":     ["Jacket","Sneakers","T-Shirt","Jeans","Hat","Scarf"],
    "sports":      ["Yoga Mat","Dumbbells","Bicycle","Tent","Running Shoes"],
    "books":       ["Novel","Cookbook","Biography","Textbook","Comic"],
}
TIERS   = ["bronze","silver","gold","platinum"]
STATUS  = ["pending","paid","shipped","delivered","returned"]
CHANNEL = ["web","mobile","store","partner"]
BASE_TS = datetime(2026, 1, 1, tzinfo=timezone.utc)

def money(x):
    """Decimal128, NEVER float. A double cannot represent 0.1 exactly, and
    currency stored as a double is a real bug that ships to production."""
    return Decimal128(Decimal(str(round(x, 2))))

customers = []
for i in range(1, N_CUSTOMERS + 1):
    city, state = random.choice(CITIES)
    customers.append({
        "_id": f"C{i:05d}",                       # our own _id, not an ObjectId
        "first_name": random.choice(FIRST),
        "last_name":  random.choice(LAST),
        "email": f"user{i}@example.com",
        "tier": random.choices(TIERS, weights=[50,30,15,5])[0],
        "loyalty_points": random.randint(0, 25_000),
        "signup_date": BASE_TS - timedelta(days=random.randint(0, 1460)),
        # NESTED — stays nested. No flattening.
        "address": {"city": city, "state": state,
                    "zip": f"{random.randint(10000,99999)}", "country": "US"},
        "preferences": {"newsletter": random.choice([True, False]),
                        "categories": random.sample(list(CATEGORIES),
                                                    k=random.randint(1,3))},
    })

products = []
for i in range(1, N_PRODUCTS + 1):
    cat = random.choice(list(CATEGORIES))
    products.append({
        "_id": f"SKU-{i:05d}",
        "name": f"{random.choice(CATEGORIES[cat])} "
                f"{random.choice(['Pro','Max','Lite','Classic','X'])}",
        "category": cat,
        "price": money(random.uniform(9.99, 1899.99)),
        "stock": random.randint(0, 500),
        "rating": round(random.uniform(2.5, 5.0), 1),
        "tags": random.sample(["new","sale","bestseller","eco","premium","clearance"],
                              k=random.randint(1,3)),
    })

orders = []
for i in range(1, N_ORDERS + 1):
    cust, items = random.choice(customers), []
    for p in random.sample(products, k=random.randint(1,5)):
        qty = random.randint(1,3)
        unit = Decimal(p["price"].to_decimal())
        items.append({"sku": p["_id"], "name": p["name"], "qty": qty,
                      "unit_price": p["price"],
                      "line_total": Decimal128(unit * qty)})
    total = sum(Decimal(it["line_total"].to_decimal()) for it in items)
    orders.append({
        "_id": f"O{i:06d}",
        "customer_id": cust["_id"],                       # a REFERENCE
        "order_ts": BASE_TS + timedelta(minutes=random.randint(0, 300_000)),
        "status": random.choices(STATUS, weights=[10,25,25,35,5])[0],
        "channel": random.choice(CHANNEL),
        "items": items,                                   # EMBEDDED
        "total": Decimal128(total),
        "ship_to": {"city": cust["address"]["city"],
                    "state": cust["address"]["state"],
                    "zip": cust["address"]["zip"]},
    })

events = [{
    "customer_id": random.choice(customers)["_id"],
    "sku": random.choice(products)["_id"],
    "event_type": random.choices(["view","add_to_cart","purchase","remove_from_cart"],
                                 weights=[70,18,7,5])[0],
    "ts": BASE_TS + timedelta(seconds=random.randint(0, 18_000_000)),
    "session_id": f"S{random.randint(1,1500):06d}",
    "device": random.choice(["ios","android","desktop","tablet"]),
} for _ in range(N_EVENTS)]

# --- Load. Drop first so the notebook is idempotent. ---
for name in ("customers", "products", "orders", "events"):
    db[name].drop()

# ordered=False parallelises and continues past failures — always use it for
# bulk loads unless insertion order genuinely matters.
db.customers.insert_many(customers, ordered=False)
db.products.insert_many(products,   ordered=False)
db.orders.insert_many(orders,       ordered=False)
db.events.insert_many(events,       ordered=False)

for name in ("customers", "products", "orders", "events"):
    print(f"  {name:<12} {db[name].count_documents({}):>6} documents")
```

```python
# --- Indexes. In Module 1 we built these by hand as Redis Sets and Sorted
# --- Sets and maintained BOTH SIDES on every write. Here the engine owns them.
db.customers.create_index([("tier", ASCENDING)])
db.customers.create_index([("address.city", ASCENDING)])       # nested field
db.customers.create_index([("preferences.categories", ASCENDING)])  # MULTIKEY
db.customers.create_index([("email", ASCENDING)], unique=True) # real constraint

db.products.create_index([("category", ASCENDING), ("price", DESCENDING)])
db.products.create_index([("tags", ASCENDING)])                # multikey
db.products.create_index([("name", "text")])                   # text search

db.orders.create_index([("customer_id", ASCENDING), ("order_ts", DESCENDING)])
db.orders.create_index([("status", ASCENDING)])
db.orders.create_index([("items.sku", ASCENDING)])             # nested + multikey

db.events.create_index([("ts", DESCENDING)])
db.events.create_index([("customer_id", ASCENDING), ("ts", DESCENDING)])
# A TTL index: MongoDB deletes events older than 90 days, automatically.
# Checked every 60 seconds — expiry is "at or after", never before.
db.events.create_index([("ts", ASCENDING)], expireAfterSeconds=7776000)

print("Indexes created.")
```

> **Pause here and compare with Module 1, §6.3.** The Redis loader needed a recursive `flatten()`, a `'|'.join()` for lists, three hand-maintained index structures written in the same pipeline as the entity, and a `K` class of key-builders to avoid typos. This loader inserts the dicts and declares six indexes. **That difference is what you buy with a document store, and the price is everything in §1.4.**

### 6.2 CREATE

#### mongosh

```javascript
use retail

// --- insertOne. Returns the _id, generating an ObjectId if you omit one. ---
db.customers.insertOne({
  _id: "C90001",
  first_name: "Ahmed", last_name: "Sami",
  email: "ahmed@example.com",
  tier: "gold",
  loyalty_points: NumberInt(1200),
  address: { city: "Houston", state: "TX", zip: "77002", country: "US" },
  preferences: { newsletter: true, categories: ["electronics"] },
  signup_date: new Date()
})

// --- insertMany. ordered:false continues past failures AND parallelises. ---
db.products.insertMany([
  { _id: "SKU-90001", name: "Test Widget", category: "home",
    price: NumberDecimal("19.99"), stock: NumberInt(10) },
  { _id: "SKU-90002", name: "Test Gadget", category: "home",
    price: NumberDecimal("29.99"), stock: NumberInt(5) }
], { ordered: false })

// --- UPSERT: insert if absent, update if present. The closest MongoDB gets
// --- to "INSERT ... ON DUPLICATE KEY UPDATE".
db.customers.updateOne(
  { _id: "C90002" },                                  // filter
  { $set:         { tier: "bronze", email: "new@example.com" },
    $setOnInsert: { signup_date: new Date(), loyalty_points: NumberInt(0) } },
  { upsert: true }                                     // <- the flag
)
// $setOnInsert applies ONLY on insert, never on update. That distinction is
// what makes upsert safe for created_at-style fields.

// --- Uniqueness is enforced by a UNIQUE INDEX, not by insert semantics. ---
try {
  db.customers.insertOne({ _id: "C90003", email: "ahmed@example.com" })
} catch (e) {
  print("E11000 duplicate key — the unique index on email did its job")
}
```

#### GUI

In Compass: select the collection → **Add Data → Insert Document** → edit as JSON or in the field-by-field editor, which shows a **BSON type dropdown per field**. That dropdown is the teaching moment — pick `Decimal128` for `price` and `Date` for `signup_date` and watch the difference from `String`.

mongo-express: **New Document** → paste JSON → Save.

#### PyMongo

```python
from pymongo.errors import DuplicateKeyError
from bson import Decimal128
from decimal import Decimal
from datetime import datetime, timezone

# --- insert_one ---
res = db.customers.insert_one({
    "_id": "C90010",
    "first_name": "Ahmed", "last_name": "Sami",
    "email": "ahmed2@example.com",
    "tier": "gold",
    "loyalty_points": 1200,
    "address": {"city": "Houston", "state": "TX", "zip": "77002"},
    "preferences": {"newsletter": True, "categories": ["electronics"]},
    "signup_date": datetime.now(timezone.utc),
})
print("inserted_id:", res.inserted_id)

# --- insert_many. ordered=False: continue past failures. The exception still
# --- raises at the END, and it carries the details of what did and did not
# --- succeed — which is why you catch BulkWriteError specifically.
from pymongo.errors import BulkWriteError
try:
    db.products.insert_many([
        {"_id": "SKU-90010", "name": "A", "category": "home",
         "price": Decimal128(Decimal("19.99")), "stock": 10},
        {"_id": "SKU-90010", "name": "DUPLICATE", "category": "home",
         "price": Decimal128(Decimal("29.99")), "stock": 5},   # same _id
        {"_id": "SKU-90011", "name": "B", "category": "home",
         "price": Decimal128(Decimal("39.99")), "stock": 7},
    ], ordered=False)
except BulkWriteError as e:
    ok = e.details["nInserted"]
    print(f"inserted {ok}, {len(e.details['writeErrors'])} failed "
          f"— with ordered=True only {1} would have been inserted")

# --- upsert ---
db.customers.update_one(
    {"_id": "C90011"},
    {"$set":         {"tier": "silver"},
     "$setOnInsert": {"signup_date": datetime.now(timezone.utc),
                      "loyalty_points": 0}},
    upsert=True,
)
```

### 6.3 READ

This is where a document store earns its keep. **Everything below is impossible or hand-built in Module 1's Redis.**

#### mongosh

```javascript
// --- 1. By primary key ---
db.customers.findOne({ _id: "C00001" })

// --- 2. By ANY field. No pre-built index required for correctness — only
// ---    for speed. This single line is the whole argument for a document
// ---    store over a key-value store.
db.customers.find({ tier: "gold" })
db.customers.countDocuments({ tier: "gold" })

// --- 3. By a NESTED field, via dot notation ---
db.customers.find({ "address.city": "Houston" })

// --- 4. Comparison operators ---
db.products.find({ price: { $gte: NumberDecimal("100"),
                            $lte: NumberDecimal("500") } })
db.customers.find({ loyalty_points: { $gt: 20000 } })
db.orders.find({ status: { $in: ["shipped", "delivered"] } })
db.orders.find({ status: { $ne: "returned" } })

// --- 5. Logical operators. Implicit AND when you list fields together. ---
db.customers.find({ tier: "gold", "address.state": "TX" })              // AND
db.customers.find({ $or: [{ tier: "gold" }, { loyalty_points: { $gt: 20000 } }] })
db.customers.find({ $and: [{ tier: { $ne: "bronze" } },
                           { "preferences.newsletter": true }] })

// --- 6. ARRAYS. Matches if ANY element matches. ---
db.products.find({ tags: "bestseller" })                    // any element
db.products.find({ tags: { $all: ["sale", "new"] } })       // ALL present
db.products.find({ tags: { $size: 3 } })                    // exactly 3 elements
db.orders.find({ "items.sku": "SKU-00001" })                // any line item

// THE TRAP, demonstrated. These two are NOT equivalent:
db.orders.find({ "items.qty": { $gte: 2 }, "items.unit_price": { $gt: NumberDecimal("500") } })
//   ^ different elements may satisfy each condition
db.orders.find({ items: { $elemMatch: { qty: { $gte: 2 },
                                        unit_price: { $gt: NumberDecimal("500") } } } })
//   ^ ONE element must satisfy BOTH. This is what you meant.

// --- 7. EXISTENCE vs NULL. These are three different things. ---
db.customers.find({ middle_name: null })                    // absent OR null
db.customers.find({ middle_name: { $exists: false } })      // ABSENT only
db.customers.find({ middle_name: { $type: "null" } })       // explicitly null
// This distinction has no SQL equivalent and it catches everyone.

// --- 8. PROJECTION — return only what you need. Less network, less parsing. ---
db.customers.find({ tier: "gold" }, { first_name: 1, last_name: 1, tier: 1 })
db.customers.find({}, { email: 0, preferences: 0 })         // exclusion
db.orders.find({ _id: "O000001" }, { "items.sku": 1, "items.qty": 1, _id: 0 })

// --- 9. SORT, SKIP, LIMIT ---
db.products.find().sort({ price: -1 }).limit(5)
db.orders.find({ customer_id: "C00001" }).sort({ order_ts: -1 }).limit(10)

// PAGINATION WARNING: skip() must WALK the skipped documents, so page 10,000
// is catastrophically slow. Use a range on an indexed field instead —
// "seek pagination" / keyset pagination:
db.orders.find({ order_ts: { $lt: lastSeenTimestamp } }).sort({ order_ts: -1 }).limit(20)

// --- 10. DISTINCT and text search ---
db.customers.distinct("tier")
db.products.distinct("category", { price: { $gt: NumberDecimal("500") } })
db.products.find({ $text: { $search: "laptop pro" } })      // needs a text index

// --- 11. EXPLAIN — how you find out what actually happened. ---
db.customers.find({ tier: "gold" }).explain("executionStats")
// The three numbers that matter:
//   totalDocsExamined  vs  nReturned   -> ratio near 1 is ideal
//   stage: "IXSCAN"    (good)  vs  "COLLSCAN" (a full scan)
//   executionTimeMillis
```

#### GUI

Compass's **Documents tab** takes the same filter JSON, with autocomplete, and shows the explain plan alongside. Its **Schema tab** answers the question no CLI can: *what shape is this data actually?*

#### PyMongo

```python
# --- Point and filter reads ---
db.customers.find_one({"_id": "C00001"})
list(db.customers.find({"tier": "gold"}).limit(5))
db.customers.count_documents({"tier": "gold"})

# --- find() returns a CURSOR, lazily. It is not a list, and iterating it
# --- twice does not work. This trips up people used to ORMs.
cursor = db.customers.find({"tier": "gold"})
first_pass  = list(cursor)
second_pass = list(cursor)          # [] — the cursor is exhausted
print(len(first_pass), len(second_pass))

# --- Straight into pandas: the analytics workflow ---
import pandas as pd
gold = pd.DataFrame(list(
    db.customers.find({"tier": "gold"},
                      {"first_name": 1, "last_name": 1,
                       "loyalty_points": 1, "address.city": 1})
    .sort("loyalty_points", DESCENDING).limit(20)
))
display(gold)

# --- Nested, arrays, and $elemMatch ---
list(db.customers.find({"address.city": "Houston"}).limit(3))
list(db.products.find({"tags": {"$all": ["sale", "new"]}}).limit(3))
list(db.orders.find({
    "items": {"$elemMatch": {"qty": {"$gte": 2},
                             "unit_price": {"$gt": Decimal128(Decimal("500"))}}}
}).limit(3))

# --- explain(), programmatically. This is how you put an assertion on
# --- performance in a test suite — genuinely worth doing.
plan = db.customers.find({"tier": "gold"}).explain()
ex   = plan["executionStats"] if "executionStats" in plan else {}
print("stage    :", plan["queryPlanner"]["winningPlan"].get("stage"))
print("index    :", plan["queryPlanner"]["winningPlan"]
                        .get("inputStage", {}).get("indexName", "NONE — COLLSCAN"))

# --- Keyset pagination: correct at any depth, unlike skip() ---
def paginate(coll, page_size=20, after=None):
    q = {"_id": {"$gt": after}} if after else {}
    batch = list(coll.find(q).sort("_id", ASCENDING).limit(page_size))
    return batch, (batch[-1]["_id"] if batch else None)

page1, cursor1 = paginate(db.customers)
page2, cursor2 = paginate(db.customers, after=cursor1)
print(f"page1: {page1[0]['_id']}..{page1[-1]['_id']}   "
      f"page2: {page2[0]['_id']}..{page2[-1]['_id']}")
```

### 6.4 UPDATE

**The rule that dominates: update the *field*, never read-modify-write the whole document.** RMW is a lost-update race under concurrency — exactly the same lesson as Module 1, §6.6.

#### mongosh

```javascript
// --- $set: change specific fields, leave the rest alone ---
db.customers.updateOne({ _id: "C00001" }, { $set: { email: "new@example.com" } })

// --- Nested update via dot notation. Does NOT replace the whole sub-document.
db.customers.updateOne({ _id: "C00001" },
  { $set: { "address.city": "Austin", "address.zip": "78701" } })

// CONTRAST — this REPLACES the entire address sub-document, silently dropping
// state, zip, and country. A very common accidental data loss.
db.customers.updateOne({ _id: "C00001" }, { $set: { address: { city: "Austin" } } })

// --- $inc / $mul: atomic arithmetic. Correct under concurrency; a
// --- read-add-write sequence is NOT.
db.customers.updateOne({ _id: "C00001" }, { $inc: { loyalty_points: 500 } })
db.products.updateOne({ _id: "SKU-00001" }, { $inc: { stock: -3 } })

// --- $unset, $rename, $min/$max, $currentDate ---
db.customers.updateOne({ _id: "C00001" }, { $unset: { referral_code: "" } })
db.customers.updateMany({}, { $rename: { "signup_date": "created_at" } })
db.products.updateOne({ _id: "SKU-00001" },
  { $max: { highest_price_seen: NumberDecimal("1499.00") } })
db.orders.updateOne({ _id: "O000001" }, { $currentDate: { updated_at: true } })

// --- ARRAY OPERATORS — the ones with no SQL equivalent ---
db.products.updateOne({ _id: "SKU-00001" }, { $push: { tags: "clearance" } })
db.products.updateOne({ _id: "SKU-00001" }, { $addToSet: { tags: "sale" } })  // no dup
db.products.updateOne({ _id: "SKU-00001" }, { $pull: { tags: "new" } })       // by value
db.products.updateOne({ _id: "SKU-00001" }, { $pop: { tags: 1 } })            // last (-1=first)

// Capped push: append, sort, and keep only the newest 10 — in ONE atomic op.
// This is how you maintain a bounded activity feed inside a document, and it
// is the direct answer to the unbounded-array trap in 5.5.
db.customers.updateOne({ _id: "C00001" }, {
  $push: { recent_events: {
    $each:  [{ type: "login", ts: new Date() }],
    $sort:  { ts: -1 },
    $slice: 10
  }}
})

// --- POSITIONAL OPERATORS: update an element INSIDE an array ---
// $ = the FIRST element matched by the query
db.orders.updateOne(
  { _id: "O000001", "items.sku": "SKU-00001" },
  { $set: { "items.$.qty": NumberInt(5) } }
)
// $[] = EVERY element
db.orders.updateOne({ _id: "O000001" }, { $mul: { "items.$[].qty": 2 } })
// $[identifier] = every element matching arrayFilters — the most precise form
db.orders.updateOne(
  { _id: "O000001" },
  { $set: { "items.$[elem].discounted": true } },
  { arrayFilters: [{ "elem.qty": { $gte: 2 } }] }
)

// --- updateMany ---
db.customers.updateMany({ tier: "bronze", loyalty_points: { $gt: 5000 } },
                        { $set: { tier: "silver" } })

// --- findOneAndUpdate: ATOMIC read-and-modify. Returns the document. ---
// This is MongoDB's compare-and-swap, and the direct analogue of Redis's
// WATCH/MULTI/EXEC from Module 1 — but it needs no retry loop, because the
// filter and the update are evaluated together on the server.
db.products.findOneAndUpdate(
  { _id: "SKU-00001", stock: { $gte: 3 } },     // the GUARD is in the filter
  { $inc: { stock: -3 } },
  { returnDocument: "after" }
)
// Returns null if stock < 3. No oversell, no race, no retry.

// --- replaceOne: swaps the WHOLE document, keeping only _id. ---
db.customers.replaceOne({ _id: "C90001" },
                        { _id: "C90001", first_name: "Only", tier: "bronze" })
// Everything else on that document is GONE. Rarely what you want.
```

#### PyMongo

```python
db.customers.update_one({"_id": "C00001"}, {"$set": {"email": "x@example.com"}})
db.customers.update_one({"_id": "C00001"},
                        {"$set": {"address.city": "Austin"},
                         "$inc": {"loyalty_points": 500}})

db.products.update_one({"_id": "SKU-00001"}, {"$addToSet": {"tags": "sale"}})

# --- find_one_and_update: atomic reserve-stock, no retry loop needed. ---
# Compare with Module 1's decrement_stock(), which needed WATCH, a manual
# retry loop, and a WatchError handler. Here the guard lives in the filter.
from pymongo import ReturnDocument

def reserve_stock(db, sku: str, qty: int):
    """Reserve qty units, or return None. Atomic, no oversell, no retry."""
    return db.products.find_one_and_update(
        {"_id": sku, "stock": {"$gte": qty}},     # the guard
        {"$inc": {"stock": -qty}},
        return_document=ReturnDocument.AFTER,
    )

print("Reserve 3 ->", (reserve_stock(db, "SKU-00001", 3) or {}).get("stock", "REFUSED"))
print("Reserve 99999 ->", "REFUSED" if reserve_stock(db, "SKU-00001", 99999) is None else "?")

# --- Array element update with arrayFilters ---
db.orders.update_one(
    {"_id": "O000001"},
    {"$set": {"items.$[elem].discounted": True}},
    array_filters=[{"elem.qty": {"$gte": 2}}],
)

# --- bulk_write for heterogeneous updates in one round trip ---
from pymongo import UpdateOne
ops = [UpdateOne({"_id": c["_id"]}, {"$inc": {"loyalty_points": 100}})
       for c in db.customers.find({"tier": "gold"}, {"_id": 1}).limit(100)]
r = db.customers.bulk_write(ops, ordered=False)
print(f"matched={r.matched_count} modified={r.modified_count}")
```

### 6.5 DELETE

```javascript
// --- delete_one / delete_many ---
db.customers.deleteOne({ _id: "C90001" })
db.customers.deleteMany({ tier: "bronze", loyalty_points: 0 })

// --- findOneAndDelete: atomic read-and-remove, returns the document ---
db.events.findOneAndDelete({ event_type: "view" })

// --- drop() vs deleteMany({}) — a real operational difference ---
db.events.deleteMany({})   // walks EVERY document; slow; keeps indexes;
                           //   space is NOT returned to the OS
db.events.drop()           // instant; removes the collection AND its indexes;
                           //   returns space immediately

// --- TTL: let MongoDB delete for you. Prefer this to a cleanup cron whenever
// --- the data is inherently time-bounded.
db.sessions.createIndex({ created_at: 1 }, { expireAfterSeconds: 1800 })
// The TTL monitor runs every 60 SECONDS, so deletion is "at or after" the
// deadline — never before, but possibly up to a minute late. Same lesson as
// Redis's probabilistic expiry in Module 1.

// --- Soft delete: the pattern most applications actually want ---
db.customers.updateOne({ _id: "C00005" },
  { $set: { deleted: true, deleted_at: new Date() } })
// Then a PARTIAL INDEX so live queries never see them and the index stays small:
db.customers.createIndex({ tier: 1 },
  { partialFilterExpression: { deleted: { $exists: false } } })
```

```python
# --- CASCADE DELETE. There is NO referential integrity — deleting a customer
# --- leaves their orders orphaned, pointing at a customer_id that no longer
# --- exists. Nothing stops you. NOTHING TELLS YOU. This is §1.4's cost,
# --- in code.
def delete_customer_cascade(db, customer_id: str) -> dict:
    """Delete a customer and everything referencing them. YOUR job, not the
    engine's. Wrap in a transaction (7.4) if partial deletion is unacceptable."""
    orders = db.orders.delete_many({"customer_id": customer_id})
    events = db.events.delete_many({"customer_id": customer_id})
    cust   = db.customers.delete_one({"_id": customer_id})
    return {"customer": cust.deleted_count,
            "orders":   orders.deleted_count,
            "events":   events.deleted_count}

print(delete_customer_cascade(db, "C00003"))

# Prove the danger first, on camera: delete a customer WITHOUT the cascade,
# then count the orphans.
orphans = db.orders.aggregate([
    {"$lookup": {"from": "customers", "localField": "customer_id",
                 "foreignField": "_id", "as": "cust"}},
    {"$match": {"cust": {"$size": 0}}},
    {"$count": "orphaned_orders"},
])
print(list(orphans))
```

---

## Part 7 — Beyond CRUD

### 7.1 Indexes — the thing the engine does for you

In Module 1 you built every secondary index by hand as a Redis Set or Sorted Set, and maintained both sides on every write. **Here the engine owns them.** That is the single biggest practical difference, and it comes with its own discipline.

| Type | What it is | Use when |
|---|---|---|
| **Single field** | `{tier: 1}` | One predicate |
| **Compound** | `{customer_id: 1, order_ts: -1}` | Multiple predicates, or filter + sort |
| **Multikey** | Automatic on an array field | Querying array contents |
| **Text** | `{name: "text"}` | Keyword search. **One per collection** |
| **Geospatial** | `{loc: "2dsphere"}` | Radius / near queries |
| **Hashed** | `{_id: "hashed"}` | **Shard keys** — spreads a monotonic key |
| **Partial** | `partialFilterExpression` | Index only rows you query. Smaller, cheaper |
| **Sparse** | `sparse: true` | Skip documents missing the field |
| **Unique** | `unique: true` | A real, engine-enforced constraint |
| **TTL** | `expireAfterSeconds` | Automatic expiry |
| **Wildcard** | `{"$**": 1}` | Unknown/variable field names |

**The compound-index prefix rule** — the single most important thing to know about MongoDB indexes:

```javascript
db.orders.createIndex({ customer_id: 1, status: 1, order_ts: -1 })

// This ONE index serves all THREE of these queries:
db.orders.find({ customer_id: "C00001" })                              // prefix
db.orders.find({ customer_id: "C00001", status: "shipped" })           // prefix
db.orders.find({ customer_id: "C00001", status: "shipped" })
         .sort({ order_ts: -1 })                                       // full

// It does NOT serve these, because they skip the leading field:
db.orders.find({ status: "shipped" })                                  // COLLSCAN
db.orders.find({ order_ts: { $gt: someDate } })                        // COLLSCAN

// RULE: an index on (A, B, C) serves queries on A, on (A,B), and on (A,B,C) —
// never on B alone or C alone. Order your compound keys by which prefixes you
// actually query. This is why THREE separate single-field indexes are usually
// worse than ONE well-ordered compound index.
```

**The ESR rule** for ordering compound keys: **E**quality first, then **S**ort, then **R**ange.

```javascript
// Query: find({status: "shipped", total: {$gt: 500}}).sort({order_ts: -1})
//   Equality -> status ; Sort -> order_ts ; Range -> total
db.orders.createIndex({ status: 1, order_ts: -1, total: 1 })   // ESR — correct
db.orders.createIndex({ status: 1, total: 1, order_ts: -1 })   // slower: the
//   range on 'total' breaks the index's ability to also satisfy the sort,
//   forcing an in-memory SORT stage.
```

```javascript
// --- COVERED QUERIES: when the index contains every field the query needs,
// --- MongoDB never touches the collection at all. The fastest thing it does.
db.customers.createIndex({ tier: 1, loyalty_points: 1 })
db.customers.find({ tier: "gold" }, { _id: 0, tier: 1, loyalty_points: 1 })
             .explain("executionStats")
// Look for  totalDocsExamined: 0  with nReturned > 0. That is a covered query.

// --- Index builds. Since 4.2 they are effectively non-blocking, but they
// --- consume CPU and I/O. On a replica set, the safe production pattern is a
// --- ROLLING BUILD: build on each secondary, then step down the primary and
// --- build on it. In this lab, just watch it:
db.orders.createIndex({ "ship_to.state": 1 })
db.currentOp({ "command.createIndexes": { $exists: true } })

// --- Audit: an index with 0 ops after weeks is pure write overhead. ---
db.orders.aggregate([{ $indexStats: {} }])
db.orders.dropIndex("ship_to.state_1")
```

> **Every index speeds reads and slows writes.** A collection with 12 indexes pays 12 B-tree updates per insert. The discipline that replaces Module 1's "you own your indexes" is: **you own your index *inventory*.** Audit with `$indexStats` and drop the dead ones.

### 7.2 The aggregation pipeline

MongoDB's answer to `GROUP BY`, joins, and window functions. Documents flow through **stages**, each transforming the stream.

```javascript
// Revenue by category — the classic GROUP BY, stage by stage.
db.orders.aggregate([
  // 1. FILTER FIRST, ALWAYS. $match early can use an index; $match late
  //    cannot, because by then the documents are synthetic pipeline output.
  { $match: { status: { $in: ["shipped", "delivered"] },
              order_ts: { $gte: ISODate("2026-01-01") } } },

  // 2. Deconstruct the items array: one output document PER ARRAY ELEMENT.
  //    This is the operation with no SQL equivalent, and it is what makes
  //    nested arrays analysable.
  { $unwind: "$items" },

  // 3. Join to products to get the category. $lookup is a LEFT OUTER JOIN
  //    and it returns an ARRAY — hence the $unwind that follows.
  { $lookup: { from: "products", localField: "items.sku",
               foreignField: "_id", as: "product" } },
  { $unwind: "$product" },

  // 4. GROUP BY. _id is the grouping key; everything else is an accumulator.
  { $group: {
      _id:        "$product.category",
      revenue:    { $sum: { $toDecimal: "$items.line_total" } },
      units:      { $sum: "$items.qty" },
      orders:     { $addToSet: "$_id" },        // distinct order ids
      avg_price:  { $avg: { $toDecimal: "$items.unit_price" } }
  }},

  // 5. Reshape. $project adds computed fields and drops what you do not need.
  { $project: {
      category:   "$_id", _id: 0,
      revenue:    { $round: [{ $toDouble: "$revenue" }, 2] },
      units:      1,
      order_count: { $size: "$orders" },
      avg_price:  { $round: [{ $toDouble: "$avg_price" }, 2] }
  }},

  { $sort: { revenue: -1 } },
  { $limit: 10 }
])
```

**The stages worth knowing, and their SQL analogues:**

| Stage | SQL analogue | Note |
|---|---|---|
| `$match` | `WHERE` | **Put it first.** Only then can it use an index |
| `$project` | `SELECT` | Add, remove, or compute fields |
| `$group` | `GROUP BY` | `_id` is the key; `null` groups everything |
| `$sort` | `ORDER BY` | 100 MB memory limit unless `allowDiskUse: true` |
| `$limit` / `$skip` | `LIMIT` / `OFFSET` | Same `skip` warning as `find()` |
| `$lookup` | `LEFT OUTER JOIN` | Returns an **array**. Usually followed by `$unwind` |
| `$unwind` | *(none)* | One output doc per array element |
| `$facet` | Multiple queries at once | Sub-pipelines over the same input — perfect for dashboards |
| `$bucket` / `$bucketAuto` | `CASE` + `GROUP BY` | Histograms |
| `$setWindowFields` | Window functions | Running totals, rank, moving averages (5.0+) |
| `$merge` / `$out` | `CREATE TABLE AS` | **Materialised views.** `$merge` upserts; `$out` replaces |
| `$graphLookup` | Recursive CTE | Hierarchy traversal — a taste of Module 4's graph |

```javascript
// --- $facet: several independent analyses in ONE pass over the data. This is
// --- the dashboard query, and it is genuinely elegant.
db.orders.aggregate([
  { $match: { order_ts: { $gte: ISODate("2026-01-01") } } },
  { $facet: {
      by_status:  [{ $group: { _id: "$status", n: { $sum: 1 } } },
                   { $sort: { n: -1 } }],
      by_channel: [{ $group: { _id: "$channel",
                               revenue: { $sum: { $toDecimal: "$total" } } } }],
      totals:     [{ $group: { _id: null, orders: { $sum: 1 },
                               revenue: { $sum: { $toDecimal: "$total" } } } }],
      top_orders: [{ $sort: { total: -1 } }, { $limit: 5 },
                   { $project: { customer_id: 1, total: 1 } }]
  }}
])

// --- $setWindowFields: a running total per customer, ordered by time. ---
db.orders.aggregate([
  { $setWindowFields: {
      partitionBy: "$customer_id",
      sortBy: { order_ts: 1 },
      output: {
        running_total: {
          $sum: { $toDecimal: "$total" },
          window: { documents: ["unbounded", "current"] }
        },
        order_rank: { $rank: {} }
      }
  }},
  { $limit: 5 }
])

// --- $merge: a MATERIALISED VIEW. Compute nightly, read instantly.
// --- This is Module 1's derived-data / CQRS pattern, native.
db.orders.aggregate([
  { $group: { _id: "$customer_id",
              lifetime_value: { $sum: { $toDecimal: "$total" } },
              order_count:    { $sum: 1 },
              last_order:     { $max: "$order_ts" } } },
  { $merge: { into: "customer_summary", on: "_id",
              whenMatched: "replace", whenNotMatched: "insert" } }
])
db.customer_summary.find().sort({ lifetime_value: -1 }).limit(5)
```

```python
# --- The same pipeline in PyMongo, straight into pandas ---
pipeline = [
    {"$match": {"status": {"$in": ["shipped", "delivered"]}}},
    {"$unwind": "$items"},
    {"$group": {"_id": "$items.sku",
                "units":   {"$sum": "$items.qty"},
                "revenue": {"$sum": {"$toDouble": "$items.line_total"}}}},
    {"$sort": {"revenue": -1}},
    {"$limit": 15},
]
# allowDiskUse lifts the 100 MB per-stage memory cap for large sorts/groups.
top = pd.DataFrame(list(db.orders.aggregate(pipeline, allowDiskUse=True)))
top.columns = ["sku", "units", "revenue"]
display(top)

# Explain an aggregation — same discipline as explaining a find().
print(db.command("explain", {
    "aggregate": "orders", "pipeline": pipeline[:2], "cursor": {}
}, verbosity="queryPlanner")["stages"][0]["$cursor"]["queryPlanner"]["winningPlan"])
```

> **`$lookup` is not a join, and this is where people get hurt.** It performs a lookup **per input document**. Joining a 2-million-document collection to another without an index on the foreign field is a 2-million-query operation. **Index `foreignField`, always.** And if you find yourself `$lookup`-ing three collections together, that is a signal you should have embedded — not a signal to write a bigger pipeline.

### 7.3 Change streams

MongoDB's answer to triggers and CDC — and a direct callback to Module 1's §2.9. **Requires a replica set**, which is why we built one.

```python
# ---------------------------------------------------------------------------
# A change stream is a CURSOR over the oplog, with a supported API, resumable
# after a crash. This is Change Data Capture, built in.
#
# Compare with Module 1: Redis keyspace notifications were FIRE-AND-FORGET
# Pub/Sub — miss a message and it is gone forever. A change stream has a
# RESUME TOKEN, so a consumer that dies picks up exactly where it left off.
# That difference is the whole reason you can build a derived store on this.
# ---------------------------------------------------------------------------
pipeline = [{"$match": {"operationType": {"$in": ["insert", "update", "replace"]}}}]

with db.orders.watch(pipeline, full_document="updateLookup") as stream:
    print("Watching orders... (insert one from mongosh in another terminal)")
    for change in stream:
        print(f"  {change['operationType']:<8} _id={change['documentKey']['_id']}")
        if change["operationType"] == "update":
            print(f"    changed fields: "
                  f"{list(change['updateDescription']['updatedFields'])}")
        # SAVE THIS. It is how you resume after a crash without losing or
        # double-processing an event.
        resume_token = change["_id"]
        break

# Resume exactly where we stopped:
# with db.orders.watch(resume_after=resume_token) as stream: ...
```

```javascript
// Watch the whole deployment, not just one collection.
db.getMongo().watch([{ $match: { "ns.db": "retail" } }])

// The oplog underneath it — seeing the mechanism makes the API make sense.
db.getSiblingDB("local").oplog.rs.find({ ns: "retail.orders" })
                                 .sort({ $natural: -1 }).limit(3)
```

**What change streams are for:** invalidating a cache (write to Redis from Module 1!), maintaining a search index, publishing to Kafka, real-time dashboards, auditing. **What they are not:** transactional. The event fires *after* the write commits, so this is eventual, not atomic.

### 7.4 Multi-document transactions

Real ACID across documents, collections, and databases. **Requires a replica set.**

```python
# ---------------------------------------------------------------------------
# The correct pattern. Note the callback API — it handles the retry logic for
# TransientTransactionError for you, which you would otherwise have to write
# by hand and would probably get wrong.
# ---------------------------------------------------------------------------
from pymongo.errors import ConnectionFailure, OperationFailure

def place_order(session, db, customer_id, sku, qty):
    """Reserve stock, create an order, and debit points — all or nothing."""
    product = db.products.find_one_and_update(
        {"_id": sku, "stock": {"$gte": qty}},
        {"$inc": {"stock": -qty}},
        session=session,                     # EVERY op must carry the session
        return_document=ReturnDocument.AFTER,
    )
    if product is None:
        raise ValueError(f"insufficient stock for {sku}")

    line_total = Decimal(product["price"].to_decimal()) * qty
    db.orders.insert_one({
        "customer_id": customer_id, "status": "pending",
        "order_ts": datetime.now(timezone.utc),
        "items": [{"sku": sku, "qty": qty,
                   "unit_price": product["price"],
                   "line_total": Decimal128(line_total)}],
        "total": Decimal128(line_total),
    }, session=session)

    db.customers.update_one({"_id": customer_id},
                            {"$inc": {"loyalty_points": int(line_total)}},
                            session=session)
    return True

with client.start_session() as session:
    try:
        session.with_transaction(
            lambda s: place_order(s, db, "C00001", "SKU-00001", 2),
            read_concern=ReadConcern("snapshot"),
            write_concern=WriteConcern(w="majority"),
        )
        print("Transaction committed.")
    except (ValueError, OperationFailure) as e:
        print(f"Rolled back: {e}")
```

**The costs, stated honestly:**

- A transaction holds a **snapshot**, and the default `transactionLifetimeLimitSeconds` is **60**. Long transactions abort.
- Writes are **buffered and applied at commit**, so a large transaction consumes memory on the primary.
- Under contention you get `WriteConflict` and retries — the callback API handles this, hand-rolled code often does not.
- On a **sharded** cluster, a cross-shard transaction runs two-phase commit, with all the coordination cost that implies.

> **The design advice survives the feature — the same sentence as Module 1, §2.4.** Multi-document transactions exist and they work. **But if you need them routinely, your documents are drawn on the wrong boundaries.** Embed what changes together. Transactions are the escape hatch, not the design.

### 7.5 Schema validation

Schema-on-read is a spectrum, not a binary — exactly as in Module 1, §3.1. MongoDB lets you opt **in** to schema-on-write per collection.

```javascript
db.createCollection("customers_validated", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "email", "tier", "schema_version"],
    properties: {
      schema_version: { bsonType: "int", minimum: 1 },
      email: { bsonType: "string",
               pattern: "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+$" },
      tier:  { enum: ["bronze", "silver", "gold", "platinum"] },
      loyalty_points: { bsonType: "int", minimum: 0 },   // INT, not string
      address: {
        bsonType: "object",
        required: ["city", "state"],
        properties: { city:  { bsonType: "string" },
                      state: { bsonType: "string", minLength: 2, maxLength: 2 } }
      },
      preferences: {
        bsonType: "object",
        properties: { categories: { bsonType: "array",
                                    items: { bsonType: "string" } } }
      }
    }
  }},
  validationLevel:  "strict",    // "moderate" = only enforce on conforming docs
  validationAction: "error"      // "warn" = log and ACCEPT — use during rollout
})

// Add validation to an EXISTING collection, in warn mode first.
db.runCommand({ collMod: "customers",
                validator: { $jsonSchema: { /* ... */ } },
                validationAction: "warn" })

// Find the documents that WOULD fail, before you switch to error mode.
db.customers.find({ $nor: [{ $jsonSchema: { /* ... */ } }] }).count()
```

> **The mature pattern is a promotion pipeline**, and it is identical to the one in Module 1: new attributes arrive in the flexible zone, get observed (Compass's Schema tab is how you observe them), and graduate into enforced structure once their shape is stable. **Always write an explicit `schema_version` field** and dispatch on it — inferring shape from field presence breaks the first time a field is legitimately optional.

---

## Part 8 — Replication, sharding, and horizontal scale

Everything so far ran against a replica set without depending on it. This part makes it the subject.

### 8.1 Replica sets — what and why

```mermaid
flowchart TB
    subgraph RS["Replica set rs0"]
        P["PRIMARY<br/>mongodb-0<br/>priority 2"]
        S1["SECONDARY<br/>mongodb-1<br/>priority 1"]
        S2["SECONDARY<br/>mongodb-2<br/>priority 1"]
        P -->|"oplog stream"| S1
        P -->|"oplog stream"| S2
        S1 <-->|heartbeat every 2s| S2
        P <-->|heartbeat| S1
        P <-->|heartbeat| S2
    end
    W["ALL WRITES"] --> P
    R1["reads (default)"] --> P
    R2["reads (readPreference=secondary)"] -.-> S1
    R2 -.-> S2
```

A replica set is **single-leader replication** — Module 1, §4.3, in the flesh. One primary accepts all writes; secondaries replicate asynchronously by tailing the oplog. **No write-write conflicts are possible**, because a single node imposes a total order. That is the defining benefit, and it is a large one.

| Member type | Votes | Holds data | Can become primary | Use for |
|---|---|---|---|---|
| **Primary** | Yes | Yes | Is | Accepts all writes |
| **Secondary** | Yes | Yes | Yes | Redundancy, optional reads |
| **Priority 0** | Yes | Yes | **No** | A remote-DC member you never want as primary |
| **Hidden** | Yes | Yes | No | Reporting, backups — invisible to clients |
| **Delayed** | Yes | Yes (lagged) | No | A rolling "oops" window against human error |
| **Arbiter** | **Yes** | **No** | No | Breaking a tie. **Use sparingly** — see below |

> **Why 3 and not 2.** A primary is elected by **majority**. With 2 members a majority is 2, so losing either leaves the survivor unable to elect itself, and the set goes **read-only**. With 3, a majority is 2, so you tolerate one failure. **Even-numbered sets buy nothing** — 4 members still need 3 for a majority, same as 5, with one more machine to lose. This is Module 1, §4.4's Raft argument, unchanged.
>
> **Arbiters are a trap.** An arbiter votes but holds no data, so a P-S-A set that loses its secondary has a primary that cannot satisfy `w:majority` — writes with majority concern hang. MongoDB's own guidance is now to prefer three data-bearing members.

### 8.2 Watch replication happen

```bash
# --- 1. Write to the primary, read from a secondary. ---
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin retail --eval '
  db.repl_demo.insertOne({_id: "x", at: new Date()},
                         {writeConcern: {w: "majority"}});
  print("written");
'

kubectl -n mongo-lab exec mongodb-1 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin retail --eval '
  db.getMongo().setReadPref("secondary");
  printjson(db.repl_demo.findOne({_id: "x"}));
'
```

```javascript
// --- 2. SEE the oplog entry. This is the mechanism, not an abstraction. ---
db.getSiblingDB("local").oplog.rs.find({ "ns": "retail.repl_demo" })
                                 .sort({ $natural: -1 }).limit(1).pretty()
// Fields worth pointing at:
//   op: "i"           insert ("u" update, "d" delete, "c" command)
//   ns: "retail.repl_demo"
//   o:  { the document }
//   ts: Timestamp     the position secondaries track

// --- 3. IDEMPOTENCY, demonstrated. Run an $inc, then look at the oplog: ---
db.repl_demo.updateOne({_id: "x"}, {$inc: {counter: 1}})
db.getSiblingDB("local").oplog.rs.find({ns: "retail.repl_demo", op: "u"})
                                 .sort({$natural: -1}).limit(1).pretty()
// The oplog records a $set to the RESULTING VALUE, not the $inc. That is what
// makes replaying it twice safe — and it is what makes crash recovery work.
```

### 8.3 Failover — watch an election

The demo that makes replication real.

```bash
# Terminal 1 — watch the topology change live.
watch -n1 "kubectl -n mongo-lab exec mongodb-1 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
  --eval 'rs.status().members.forEach(m => print(m.name.split(\".\")[0] + \" -> \" + m.stateStr))'"

# Terminal 2 — kill the primary.
kubectl -n mongo-lab delete pod mongodb-0

# Watch: mongodb-0 goes (not reachable/healthy) -> an election runs ->
# mongodb-1 or -2 becomes PRIMARY within ~10s -> mongodb-0 restarts,
# rejoins as SECONDARY, catches up from the oplog, and because its priority
# is 2, triggers a SECOND election to take primacy back.
```

```python
# Prove the DRIVER handles it. Run this in a notebook, then kill the primary
# in another terminal and watch the output.
import time
from pymongo.errors import AutoReconnect

for i in range(60):
    try:
        db.failover_demo.insert_one({"i": i, "at": datetime.now(timezone.utc)})
        print(f"  {i:3d} ok    primary={client.primary}")
    except AutoReconnect as e:
        # The driver's background monitor notices, re-discovers the topology,
        # and retryWrites=True retries the write ONCE against the new primary.
        print(f"  {i:3d} RETRY  {e}")
    time.sleep(1)
```

> **What this shows, and what it does not.** A brief write outage during the election is unavoidable — that is the cost of single-leader replication. `retryWrites=True` masks it for a *single* retryable write. It does **not** make a multi-step business operation atomic across a failover; that is what transactions and idempotency keys are for.

### 8.4 Write concern — how much durability do you want?

Module 1's durability ladder, with a replication dimension added.

```mermaid
flowchart LR
  A["Client sends write"] --> B["w:0 — fire and forget<br/>no acknowledgement at all"]
  B --> C["w:1 — the PRIMARY acknowledged<br/>lost if it dies before replicating"]
  C --> D["j:true — journalled on the primary<br/>survives a primary crash"]
  D --> E["w:majority — a MAJORITY acknowledged<br/>survives losing the primary"]
  E --> F["w:majority + j:true<br/>slowest, strongest"]
```

| Write concern | Survives | Cost |
|---|---|---|
| `{w: 0}` | Nothing. You do not even learn about errors | Fastest |
| `{w: 1}` *(default)* | Primary process crash **only if journalled** | Fast |
| `{w: 1, j: true}` | Primary crash | One fsync |
| **`{w: "majority"}`** | **Loss of the primary** | Network round trip to a majority |
| `{w: "majority", j: true}` | Loss of the primary **and** simultaneous crashes | Slowest |

```javascript
db.orders.insertOne({ /* ... */ },
  { writeConcern: { w: "majority", j: true, wtimeout: 5000 } })

// ALWAYS set wtimeout with w:majority. Without it, a write blocks FOREVER if
// a majority is unreachable. With it, you get a timeout error you can handle.
//
// AND KNOW THIS: a wtimeout error does NOT mean the write failed. It means it
// was not CONFIRMED in time. It may still commit and replicate afterwards.
// That ambiguity is Module 1, §5.1 — "a timeout is the absence of
// information" — appearing again.
```

**Rollback: the failure mode people don't anticipate.** A primary accepts a `w:1` write, dies before replicating it, and a secondary that never saw it is elected. When the old primary rejoins, its extra write **conflicts with the new history and is rolled back** — written to a rollback file on disk and removed from the database. The client was told it succeeded.

> **"The database said OK" and "the write survived" are different claims.** Word for word from Module 1, §6.9. `w:majority` is what closes the gap.

### 8.5 Read preference and read concern — two different dials

| `readPreference` | Reads from | Use for |
|---|---|---|
| `primary` *(default)* | Primary only | Read-your-writes correctness |
| `primaryPreferred` | Primary, else a secondary | Availability over freshness |
| `secondary` | Secondaries only | Analytics, reporting |
| `secondaryPreferred` | Secondaries, else primary | Dashboards |
| `nearest` | Lowest latency member | Geo-distributed reads |

| `readConcern` | You see | Note |
|---|---|---|
| `local` *(default)* | The member's most recent data | **May be rolled back later** |
| `available` | Same, no shard consistency check | Sharded clusters only |
| **`majority`** | Data acknowledged by a majority | **Cannot be rolled back** |
| `linearizable` | Reflects all prior majority writes | Primary only, slow, needs `maxTimeMS` |
| `snapshot` | A consistent point-in-time snapshot | Transactions |

```python
# The two dials are INDEPENDENT and they answer different questions:
#   readPreference -> WHICH MEMBER serves the read
#   readConcern    -> WHAT DURABILITY that data has

# A reporting query: cheap, stale, off the primary.
reports = db.get_collection("orders",
    read_preference=ReadPreference.SECONDARY_PREFERRED,
    read_concern=ReadConcern("local"))

# A financial read: authoritative and non-rollbackable.
ledger = db.get_collection("orders",
    read_preference=ReadPreference.PRIMARY,
    read_concern=ReadConcern("majority"))
```

**Causal consistency** — read-your-writes across members, which is Module 1's §6.5 session guarantee, native:

```python
# WITHOUT a session, this can fail: the write goes to the primary, the read
# goes to a secondary that has not caught up, and the document appears missing.
with client.start_session(causal_consistency=True) as session:
    db.customers.update_one({"_id": "C00001"},
                            {"$set": {"tier": "platinum"}}, session=session)
    # The driver attaches the operation time to the read. A secondary that has
    # not caught up WAITS until it has, rather than returning stale data.
    doc = db.customers.find_one({"_id": "C00001"}, session=session)
    print("read-your-writes:", doc["tier"])
```

### 8.6 Sharding — horizontal scale

Replication scales **reads** and buys availability. **Only sharding scales writes** — the same sentence as Module 1, §4.2.

```mermaid
flowchart TB
    APP["Application"] --> MONGOS1["mongos router"]
    APP --> MONGOS2["mongos router"]
    MONGOS1 --> CFG[("Config servers<br/>(a replica set)<br/>chunk map, shard list,<br/>balancer state")]
    MONGOS2 --> CFG
    MONGOS1 --> SH1
    MONGOS1 --> SH2
    MONGOS1 --> SH3
    MONGOS2 --> SH1
    MONGOS2 --> SH2
    MONGOS2 --> SH3
    subgraph SH1["Shard A — a replica set"]
        A1["P"]; A2["S"]; A3["S"]
    end
    subgraph SH2["Shard B — a replica set"]
        B1["P"]; B2["S"]; B3["S"]
    end
    subgraph SH3["Shard C — a replica set"]
        C1["P"]; C2["S"]; C3["S"]
    end
```

Three components, each with a job:

- **Shards** hold the data. **Each shard is itself a replica set** — so sharding and replication compose, exactly as in Module 1, §4.5. Sharding without replication would mean losing a node loses a slice of the data.
- **Config servers** (a replica set) hold the **chunk map**: which key ranges live on which shard.
- **`mongos`** routers are stateless. They cache the chunk map, route each query to the right shard(s), and merge results. Your application talks only to `mongos`.

**Chunks and the balancer.** MongoDB splits the shard-key space into **chunks** (128 MB default). When shards become unbalanced, the **balancer** migrates chunks in the background. This is automatic, unlike Redis Cluster's explicit slot migration in Module 1 — more convenient, less inspectable.

#### The shard key is the decision

Highest-leverage, hardest to reverse. A good shard key has:

- **High cardinality** — enough distinct values to spread across all shards, and to keep spreading as you grow
- **Low frequency** — no single value dominating
- **Non-monotonic** — otherwise every insert lands on the "max" chunk, on one shard
- **Present in your common queries** — otherwise every read is a **scatter-gather** to every shard

```javascript
// --- BAD: _id (ObjectId) is MONOTONIC. Every insert goes to the last chunk,
// --- on one shard. This is the monotonic hotspot from Module 1, §4.2.
sh.shardCollection("retail.orders", { _id: 1 })                   // DON'T

// --- BETTER: hashed. Spreads writes perfectly evenly...
sh.shardCollection("retail.orders", { _id: "hashed" })
// ...but DESTROYS range queries: "orders in January" now scatters to every
// shard. You traded one problem for another. Choose knowingly.

// --- USUALLY BEST: a compound key that matches your access pattern.
// customer_id gives cardinality and appears in most queries; order_ts gives
// range locality WITHIN a customer.
sh.shardCollection("retail.orders", { customer_id: 1, order_ts: 1 })

// A query carrying the shard key is TARGETED to one shard.
db.orders.find({ customer_id: "C00001" })                  // 1 shard
// A query without it SCATTERS to every shard and merges.
db.orders.find({ status: "shipped" })                      // ALL shards
```

> **Scatter-gather is the tail-latency amplification from Module 1, §1.3.** A query hitting all 10 shards waits for the **slowest** one. If each shard is p99-slow 1% of the time, ~10% of those queries are slow. **This is the quantitative argument for putting the shard key in your queries**, and it is why the shard key must be chosen from the query pattern, not from the data model.

Since 5.0 you can **reshard** (`reshardCollection`) and since 4.4 you can **refine** a key by adding suffix fields — but both are expensive online operations. **Choose carefully the first time.**

#### Zone sharding

Pin key ranges to specific shards — for data residency (GDPR, financial localisation) or tiered storage:

```javascript
sh.addShardToZone("shard-eu", "EU")
sh.updateZoneKeyRange("retail.customers",
                      { region: "EU", customer_id: MinKey },
                      { region: "EU", customer_id: MaxKey }, "EU")
// EU customers now physically live on EU hardware. Data residency becomes a
// SCHEMA concern rather than an application concern — Module 1, §4.5.
```

#### Should you shard?

```mermaid
flowchart TB
  Q0{"Have you MEASURED a limit,<br/>or are you anticipating one?"}
  Q0 -->|Anticipating| STOP["STOP. A replica set on one<br/>big machine handles far more<br/>than you think. Revisit with numbers."]
  Q0 -->|Measured| Q1{"Which limit?"}
  Q1 -->|"Read throughput"| R["Add SECONDARIES<br/>+ readPreference. Not sharding."]
  Q1 -->|"Working set > RAM"| M["Scale UP first.<br/>Servers with 1-2 TB RAM exist."]
  Q1 -->|"WRITE throughput past one primary"| S["SHARD. This is the only<br/>technique that scales writes."]
  Q1 -->|"Dataset > one disk"| S
  Q1 -->|"Data residency / geo-latency"| Z["SHARD with ZONES."]
```

> **Question 0 is the one people skip and the one that matters most** — word for word from Module 1, §9.1. Sharding adds config servers, routers, a balancer, cross-shard query semantics, and a shard key you cannot easily change. **Shard because you measured a ceiling, not because the architecture diagram looked better with three boxes.**
>
> And as in Module 1: **shard while you still have headroom.** Chunk migration consumes exactly the resources a saturated cluster is short of. Rebalancing is a background task on a healthy cluster and an outage on a busy one.

#### Trying it in the lab

A full sharded cluster is 3 config servers + 2–3 shards × 3 members + 2 `mongos` — roughly 14 pods. That does not fit alongside everything else on a laptop. Two options:

```bash
# --- Option A: a MINIMAL sharded cluster, single-member components. ---
# Not HA, but every sharding COMMAND behaves identically, which is the point.
# See k3s/optional-sharding/ for the manifests.

# --- Option B: explore the metadata on the replica set you already have. ---
kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin --eval '
  print("Is this a shard member? " + (db.serverStatus().sharding ? "yes" : "no"));
  print("The config database is empty until sharding is enabled:");
  printjson(db.getSiblingDB("config").getCollectionNames());
'
```

The commands you would run, in order:

```javascript
sh.status()                                     // cluster overview
sh.enableSharding("retail")                     // per DATABASE first
db.orders.createIndex({ customer_id: 1, order_ts: 1 })   // the key must be indexed
sh.shardCollection("retail.orders", { customer_id: 1, order_ts: 1 })

db.orders.getShardDistribution()                // docs and size per shard
sh.getBalancerState()
sh.stopBalancer()                               // during a maintenance window
sh.startBalancer()

// Which shards did this query touch? The single most useful sharding
// diagnostic — it tells you targeted vs scatter-gather at a glance.
db.orders.find({ customer_id: "C00001" }).explain().queryPlanner.winningPlan.shards
```

### 8.7 Comparing the two modules' distribution stories

| | Redis (Module 1) | MongoDB (this module) |
|---|---|---|
| Replication | Async single-leader; Sentinel for failover | Async single-leader; **built-in elections** |
| Failover mechanism | Sentinel quorum / Cluster gossip — **not a consensus log** | **Raft-derived** replica set protocol |
| Sharding | 16,384 fixed hash slots, `CRC16(key)` | **Chunk ranges** on a shard key, auto-balanced |
| Co-location control | **Hash tags** `{user:1}` | **Compound shard key** |
| Rebalancing | Explicit slot migration | **Automatic balancer** |
| Multi-key across shards | **Illegal** (`CROSSSLOT`) | Allowed; **scatter-gather or 2PC** |
| Durability dial | `appendfsync` | `writeConcern` + `journal` |
| Read scaling | Replicas | `readPreference` |
| Consistency ceiling | Linearizable per key | **Causal sessions, snapshot transactions** |

> **The same theorem, twice.** Redis Cluster needs a majority to elect; MongoDB needs a majority to elect; `w:majority` needs a majority to acknowledge. **Majorities of the same set must overlap.** Module 1, §5.5 — one idea, three appearances, across two databases.

---

## Part 9 — Where this goes next

| Module | Family | Product | Same dataset, different question |
|---|---|---|---|
| 1 | Key-value | Redis | "Give me customer C00001" in 100 µs |
| **2 (this)** | **Document** | **MongoDB** | **"Find all orders with a line item over $500" — no pre-built index needed** |
| 3 | Wide-column | Cassandra | "All orders for customer X in Q1, time-ordered" at petabyte scale |
| 4 | Graph | Neo4j | "Customers who bought what C00001 bought, 2 hops out" |
| 5 | Search / vector | OpenSearch / Atlas Vector | "Products semantically similar to this description" |

**What Module 2 bought you over Module 1**, concretely:

| Question | Redis | MongoDB |
|---|---|---|
| Get customer C00001 | `HGETALL` — ~100 µs | `findOne` — ~1 ms |
| All gold-tier customers | Only via a Set you built and maintain | `find({tier: "gold"})` |
| Customers in Houston | Another hand-built Set | `find({"address.city": "Houston"})` |
| **Orders with a line item > $500** | **Impossible without a new index** | `find({"items.line_total": {$gt: 500}})` |
| Revenue by category | Application-side | One aggregation pipeline |
| Keep the nested shape | Flattened to dotted field names | Native |

**And what it cost:** ~10× the point-read latency, a heavier operational footprint, and no referential integrity. **That is the conservation law from Module 1, §0.3 — a database does not eliminate complexity, it relocates it.**

---

## Appendix A — Troubleshooting

### Connection and authentication

| Symptom | Cause | Fix |
|---|---|---|
| `Authentication failed` with correct credentials | Missing `authSource=admin` | Users live in `admin`; add `--authenticationDatabase admin` or `?authSource=admin` |
| `MongoServerError: command requires authentication` | Connected without credentials | `security.authorization` is enabled — always authenticate |
| Host client hangs, then `ServerSelectionTimeoutError` | Driver discovered in-cluster DNS names your host cannot resolve | Add **`?directConnection=true`** (§3.6) |
| `not primary and secondaryOk=false` | Read sent to a secondary | Set `readPreference`, or connect with `replicaSet=rs0` |
| `not master` on a write | Write sent to a secondary via the ClusterIP Service | Use the replica-set URI with seeds, not the ClusterIP |
| Compass connects but shows no databases | Authenticated as a user with no roles on them | Check `db.getUser()`; `retail_app` only sees `retail` |

### Replica set

| Symptom | Cause | Fix |
|---|---|---|
| `NotYetInitialized` | `rs.initiate()` never ran | Re-run the init Job: `kubectl -n mongo-lab delete job mongodb-init && kubectl apply -f k3s/40-*.yaml` |
| Members stuck in `STARTUP` / `(not reachable)` | Members cannot resolve each other | Check the headless Service and `publishNotReadyAddresses: true` |
| `rs.conf()` shows **IP addresses** | Initiated with IPs instead of DNS names | **Will break on the next reschedule.** `rs.reconfig()` with hostnames now |
| Members never form a set; `permission denied` in the log | Keyfile mode is not 0400, or differs between members | The init container must `chmod 0400`; the Secret must be identical |
| Election never completes | Even number of voting members, or no majority reachable | Use an odd number; check all pods are Running |
| `w:majority` writes hang | No majority available (e.g. P-S-A with the secondary down) | Prefer 3 data-bearing members over an arbiter |
| Secondary stuck `RECOVERING` | Fell behind the **oplog window** | Increase `oplogSizeMB`; the member needs a full initial sync |

### Pods and manifests

| Symptom | Cause | Fix |
|---|---|---|
| `mongodb-N` CrashLoopBackOff, **exit 137** | Container limit below WiredTiger cache + overhead | Raise the limit, or lower `cacheSizeGB`. Ours: 0.5 GB cache in a 1.5 Gi limit |
| `Permission denied` on `/data/db` | PVC not writable by UID 999 | `securityContext.fsGroup: 999` |
| **Jupyter exits with `invalid literal for int()... 'tcp://<ip>:8888'`** | The Service named `jupyter` injects `JUPYTER_PORT=tcp://...` | **`enableServiceLinks: false`** + explicit `JUPYTER_PORT` (§60-jupyter.yaml) |
| mongo-express restarts repeatedly | It retries the Mongo connection while the set is still electing | Expected during bootstrap; the readiness probe allows 2 minutes |
| Two Jupyter pods, old one still serving | Default RollingUpdate racing on a RWO PVC | `strategy: { type: Recreate }` |
| ConfigMap edited, nothing changed | `mongod` parsed the file once at startup | `kubectl rollout restart statefulset/mongodb` |
| Init Job fails: "already initialized" | The Job re-ran | Harmless — it is idempotent and catches this |

### Query and data

| Symptom | Cause | Fix |
|---|---|---|
| Query slow, `explain` shows `COLLSCAN` | No usable index | Create one; check the **prefix rule** (§7.1) |
| Compound index unused | Query skips the leading field | Reorder the key by **ESR**, or add another index |
| `$elemMatch` results differ from dotted query | Dotted conditions can match **different array elements** | Use `$elemMatch` when one element must satisfy all (§5.6) |
| Money arithmetic slightly wrong | Stored as `double` | Use `Decimal128` / `NumberDecimal` |
| `{field: null}` returns unexpected documents | `null` matches both explicit null **and absent** | Use `$exists` / `$type` (§6.3) |
| `E11000 duplicate key` | A unique index rejected the write | Intended behaviour |
| Sort fails: "Sort exceeded memory limit" | >100 MB in-memory sort | Index the sort field, or `allowDiskUse: true` |
| TTL documents not deleted on time | TTL monitor runs every 60 s | Expected — "at or after", never before |
| `$lookup` catastrophically slow | No index on `foreignField` | **Always index the foreign field** |
| Transaction aborts with `TransientTransactionError` | Write conflict | Use `session.with_transaction()`, which retries |
| Deleted documents, disk did not shrink | WiredTiger does not return space by default | `db.runCommand({compact: "<coll>"})` on a secondary |

---

## Appendix B — Teardown

```bash
# Export anything you want to keep FIRST.
kubectl -n mongo-lab exec mongodb-0 -- mongodump \
  -u admin -p 'MongoLab2026!' --authenticationDatabase admin \
  --db retail --archive=/tmp/retail.archive --gzip
kubectl -n mongo-lab cp mongodb-0:/tmp/retail.archive ./retail.archive

JPOD=$(kubectl -n mongo-lab get pod -l app=jupyter -o jsonpath='{.items[0].metadata.name}')
kubectl -n mongo-lab cp "$JPOD":/home/jovyan/work ./work-backup

# Remove the lab. NOTE: deleting the namespace deletes the PVCs too, unlike a
# StatefulSet deletion, which deliberately preserves them.
kubectl delete namespace mongo-lab
kubectl get pv                       # local-path reclaims the directories

# Keep the data, remove only the workloads:
# kubectl -n mongo-lab delete statefulset mongodb --cascade=orphan
# ^ --cascade=orphan leaves the pods running. Without it, pods go but PVCs stay.

# Delete PVCs explicitly if you removed the StatefulSet but kept the namespace:
# kubectl -n mongo-lab delete pvc -l app=mongodb
```

---

## Appendix C — Command quick reference

### Connect

| Goal | mongosh | PyMongo |
|---|---|---|
| In-pod interactive | `kubectl -n mongo-lab exec -it mongodb-0 -- mongosh -u admin -p --authenticationDatabase admin` | — |
| One-shot | `kubectl -n mongo-lab exec mongodb-0 -- mongosh --quiet --eval '...'` | `client.admin.command("ping")` |
| Ephemeral client pod | `kubectl run mongo-client --rm -it --restart=Never --image=mongo:8.0 -- mongosh "mongodb://..."` | — |
| From the host | `mongosh "mongodb://...@localhost:30017/?directConnection=true&authSource=admin"` | `MongoClient(uri)` |
| Replica-set aware | add `?replicaSet=rs0` with all seeds | same URI |

### Validate

| Goal | mongosh | PyMongo |
|---|---|---|
| Liveness | `db.adminCommand("ping")` | `client.admin.command("ping")` |
| Topology | `db.hello()` | `client.topology_description` |
| Replica set status | `rs.status()` | `client.admin.command("replSetGetStatus")` |
| Replication lag | `rs.printSecondaryReplicationInfo()` | computed from `replSetGetStatus` |
| Server metrics | `db.serverStatus()` | `client.admin.command("serverStatus")` |
| DB stats | `db.stats()` | `db.command("dbStats")` |
| Collection stats | `db.coll.stats()` | `db.command("collStats", "coll")` |
| Index list | `db.coll.getIndexes()` | `db.coll.list_indexes()` |
| Index usage | `db.coll.aggregate([{$indexStats:{}}])` | same via `aggregate` |

### Administer

| Goal | mongosh | PyMongo |
|---|---|---|
| Create user | `db.createUser({...})` | `db.command("createUser", ...)` |
| Current ops | `db.currentOp()` | `client.admin.command("currentOp")` |
| Kill an op | `db.killOp(id)` | `client.admin.command("killOp", op=id)` |
| Profiler on | `db.setProfilingLevel(1, {slowms: 50})` | `db.command("profile", 1, slowms=50)` |
| Read slow ops | `db.system.profile.find().sort({ts:-1})` | `db.system.profile.find(...)` |
| Step down primary | `rs.stepDown(60)` | `client.admin.command("replSetStepDown", 60)` |
| Reconfigure set | `rs.reconfig(cfg)` | `client.admin.command("replSetReconfig", cfg)` |
| **Durable config change** | **ConfigMap + rollout restart** | **same — not a client operation** |

### Author

| Goal | mongosh | PyMongo |
|---|---|---|
| Insert one | `db.c.insertOne({...})` | `db.c.insert_one({...})` |
| Insert many | `db.c.insertMany([...], {ordered:false})` | `db.c.insert_many([...], ordered=False)` |
| Upsert | `db.c.updateOne(f, u, {upsert:true})` | `db.c.update_one(f, u, upsert=True)` |
| Find | `db.c.find(f, proj)` | `db.c.find(f, proj)` |
| Atomic modify | `db.c.findOneAndUpdate(f, u, {returnDocument:"after"})` | `db.c.find_one_and_update(f, u, return_document=ReturnDocument.AFTER)` |
| Array element | `{$set:{"a.$[e].x":1}}, {arrayFilters:[...]}` | `array_filters=[...]` |
| Bulk mixed ops | `db.c.bulkWrite([...])` | `db.c.bulk_write([...], ordered=False)` |
| Aggregate | `db.c.aggregate([...])` | `db.c.aggregate([...], allowDiskUse=True)` |
| Create index | `db.c.createIndex({a:1})` | `db.c.create_index([("a", ASCENDING)])` |
| Transaction | `session.withTransaction(fn)` | `session.with_transaction(fn)` |
| Change stream | `db.c.watch([...])` | `db.c.watch([...])` |
| Explain | `db.c.find(f).explain("executionStats")` | `db.c.find(f).explain()` |

---

## Instructor's quick-reference: the takeaways

1. **A document store is a key-value store that agreed to parse the value.** Every capability MongoDB has that Redis lacks follows from that one concession.
2. **The document is the aggregate** — the unit of retrieval, distribution, and atomicity. Single-document writes are always atomic, however deeply nested.
3. **BSON is not JSON.** Typed, binary, 16 MB max. **Use `Decimal128` for money**; a `double` cannot represent `0.1`.
4. **16 MB is a hard ceiling, and unbounded arrays are the #1 modelling failure.** Bucket or reference — the same lesson as Module 1's Redis aggregates.
5. **Embed for locality; reference for sharing and unboundedness.** This is the modelling decision, made per relationship.
6. **MongoDB's hierarchy looks like SQL's, but a collection declares nothing.** A database *is* a real security boundary — a genuine upgrade over Redis's numbered databases — but still not a resource boundary.
7. **`null` and an absent field are different things**, and they match different queries. No SQL equivalent.
8. **Arrays match if *any* element matches.** Use `$elemMatch` when conditions must be satisfied by the *same* element. This is a wrong-answer bug, not an error.
9. **The engine maintains your indexes — but only the ones you create.** Learn the **prefix rule** and **ESR**, and audit with `$indexStats`.
10. **`$lookup` is not a join.** Index the foreign field; three-way lookups mean you should have embedded.
11. **`$match` first, always.** Only then can a pipeline stage use an index.
12. **Transactions are real and they work — and needing them routinely means your document boundaries are wrong.**
13. **Change streams are resumable**, unlike Redis keyspace notifications. That is what makes them a CDC substrate rather than a best-effort trigger.
14. **Replication scales reads; only sharding scales writes.** And the shard key must come from the query pattern, not the data model.
15. **`w:majority` is what makes "the database said OK" mean "the write survived."** Always set `wtimeout` with it.
16. **Shard because you measured a ceiling**, and shard while you still have headroom.
17. **`enableServiceLinks: false`.** Kubernetes injects `<SERVICENAME>_PORT=tcp://...`, and `MONGODB_PORT` / `JUPYTER_PORT` collide with variables those applications read. Same class of bug as "a container's localhost is not your localhost."
