---
name: project_wk_cachestorage_disk_records_invisible
description: RESOLVED — PW's bootstrap.diff patches Coder<ResourceResponseData>::decodeForPersistence to read httpRequestHeaderFields but never adds the matching encoder line, so every CacheStorage record we write is 8 bytes short and no build can read it back
metadata:
  type: project
---

`defaultbrowsercontext-2.spec.ts:285 CacheStorage entry should survive
page.reload()` is red on our WebKit. The test name misleads twice: the reload is
irrelevant (the entry is already unreadable in the same session) and it is not a
persistence bug.

**Root cause.** Upstream writes the persistence coder as an explicit field list:

```cpp
void Coder<WebCore::ResourceResponseData>::encodeForPersistence(Encoder& encoder, const WebCore::ResourceResponseData& data)
{
    ...
    encoder << data.httpHeaderFields;
    encoder << data.httpStatusCode;      // httpRequestHeaderFields never written
```

`bootstrap.diff` adds `httpRequestHeaderFields` to the struct and adds
`decoder >> httpRequestHeaderFields` to `decodeForPersistence`, but adds nothing
to `encodeForPersistence` — a new struct member does not reach a hand-written
list on its own. Decode then eats the empty map's 8 bytes out of
`httpStatusCode`, runs off the blob, `decodeRecordHeader` returns nullopt and
`readAllRecordInfosInternal` does a bare `continue`. No log, so an unreadable
record presents as an EMPTY cache. Both PW series carry the omission (v1.62.1
and main) — same family as [[project_wk_closepage_hang]]: PW's published
bootstrap.diff is not the whole of what builds their shipped browser.

Fixed by `patch_persistence_encode_request_headers` in `prep-source.sh`.

**The experiment that found it** — `webkit/probes/cachestorage-record-readback.cjs`,
run twice against ONE profile so both builds' records share a directory, salt,
uuid and origin:

| record | written by | read by ours | read by official |
|---|---|---|---|
| `/meta`  624 B | official | yes | yes |
| `/meta2` 618 B | ours     | no  | no  |

Holding the profile constant is what makes it conclusive: read path, directory
names, salts, `cacheslist` and `origin` are all shared, so only the write path is
left ([[feedback_cross_read_separates_write_from_read]]).

**Two earlier readings were wrong.** "Read path broken" came from the file tree
looking right. "Encoder and decoder disagree inside one binary, so it is
conditional compilation" was closer but blamed the build — it is a source
asymmetry PW shipped. Two experiments were also VOID: splicing 8 zero bytes into
the record and grafting official's header onto ours both leave the metadata's own
`Decoder::verifyChecksum()` stale, so they fail for a reason of their own making,
and the graft's `identical=true` control could not catch it (it changes nothing,
so it re-verifies nothing).

Record grammar, verified: `headerOffset` is 226, `headerHash` at 149 and
`headerSize` at 169, and `SHA1(salt ‖ headerData)` reproduces `headerHash`. The
per-field checksums use `Encoder::Salt<T>::value` constants, so a naive SHA1 over
the blob never matches — a mismatch there is your model, not the data.

One of the shards holding
[[project_wk_promote_gate_holds_the_nightly_bench]].
