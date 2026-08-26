---
name: project_wk_cachestorage_disk_records_invisible
description: WebKit CacheStorage on musl writes a record whose response header is 8 bytes SHORT, so every reader (ours AND official) silently skips it; cross-read proves the bug is in our ENCODER, gap is at optional<NetworkLoadMetrics>
metadata:
  type: project
---

`defaultbrowsercontext-2.spec.ts:285 CacheStorage entry should survive
page.reload()` is red on our WebKit. Two things the test name gets wrong: the
reload is irrelevant, and it is not a persistence bug.

Repro in ~40 s:
`webkit/probes/run-capture-probe.sh <tag> cachestorage-reload.cjs`

**Cross-read is the decisive experiment** (write with one build, read with the
other, sharing a volume and a PINNED port — the cache is keyed by origin, so a
random port makes every cell trivially empty):

| writer | reader | result |
|---|---|---|
| official | official | `payload` |
| official | **ours** | **`payload`** |
| **ours** | official | `keys=[] match=null` |
| ours | ours | `keys=[] match=null` |

So **our read path is correct** — it reads official's data fine — and our
**write** produces a record nothing can enumerate. An earlier note here said the
opposite ("write works, read broken"); that was inferred from the file tree
looking right, and the cross-read refuted it.

What is wrong with the bytes. All four content gates in
`readRecordInfoFromFileData` PASS on our record — version is 16, `timeStamp` is
0.0 (not future), and `SHA1(salt‖headerData)` reproduces the stored
`headerHash` exactly. But:

- our `headerSize` = **377**, official's = **385**
- the two header blobs are byte-identical apart from the timestamp and the port
- the whole 8-byte gap is in ONE place: right after the `httpHeaderFields` map
  (`Content-Type: text/plain;charset=UTF-8`) official emits `0000000000000000`
  and we emit nothing

Per `WebCoreArgumentCoders.serialization.in`, the field encoded immediately
after `httpHeaderFields` in `ResourceResponseData` is
`std::optional<WebCore::NetworkLoadMetrics> networkLoadMetrics`.

Being 8 bytes short makes the decoder overrun into the trailing checksum, so
`decodeRecordHeader` returns nullopt and `readAllRecordInfosInternal` does
`continue` — **silently**, no log, which is why it presents as an empty cache
rather than an error.

Our own decoder expects 385 (it reads official's), so encoder and decoder
disagree **inside one binary**. That points at conditional compilation — a
feature macro visible to one translation unit and not another, the classic
WebKit unified-sources hazard.

**How to apply:** dig site is the generated persistence coder for
`ResourceResponseData` / `NetworkLoadMetrics`, not `CacheStorageDiskStore.cpp`
(its encoder and decoder field lists match exactly). Not a regression from the
4d05d732 base move — `wk-sha-6cc6847` fails identically. One of the shards
holding [[project_wk_promote_gate_holds_the_nightly_bench]].
