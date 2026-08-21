---
name: wk-closepage-hang
description: WebKit page.close() hangs on musl because PW's published bootstrap.diff omits Playwright.closePage — sendMayFail swallows the -32601, the page never closes, and Page._close() blocks on closedPromise; root cause of the ~64-test persistent-context cluster
metadata:
  type: project
---

**Every `page.close()` on our WebKit build hangs.** Chain, all read from PW
v1.62.1 source, not inferred:

```
page.close() → Page._close()                       (server/page.ts)
  → delegate.closePage(false) → WKPage.closePage   (webkit/wkPage.ts:837)
    → sendMayFail('Playwright.closePage')          ← our build: -32601, SWALLOWED
  → await this.closedPromise                       ← never settles
```

The browser never closes the page, so it never emits
`Playwright.pageProxyDestroyed`; `_onPageProxyDestroyed` never fires,
`wkPage.didClose()` never runs, `closedPromise` never resolves. Bounded only by
the surrounding timeout — hence the **2-minute `launchPersistentContext`** and
**two live pageProxies where one is expected**.

**The complete protocol gap** (our `Playwright.json` vs `protocol.json` inside
PW's published `webkit-2336` zip — 21 vs 20 commands):

| gap | note |
|---|---|
| `closePage` command | the hang |
| `Cookie.partitionKey` | client sends only when set; low blast radius |
| `SetCookieParam.partitionKey` | same |

types/events otherwise identical. Checked v1.60.0, v1.62.1 AND main — **none**
of the published patch sets declares `closePage`, and `patches/` holds only
`bootstrap.diff`, so this is not a stale-tag problem. The tag's series still
closes pages the old way via `PageInspectorTargetProxy::close` (`Target.close`)
while the client moved to `Playwright.closePage`.

**Fix** (b49430e): `patch_playwright_close_page()` in `prep-source.sh`, modelled
on its `setPageZoomFactor` neighbour — `m_pageProxyChannels.get(pageProxyID)`
then `tryClose()` (runBeforeUnload) or `closePage()`, mirroring
`PageInspectorTargetProxy::close`. `bool tryClose()` / `void closePage()` both
exist at pinned base `343e13bf`; bootstrap.diff already calls them in 4 places.

**Control:** `conformance-ubuntu-webkit` passed 21/21 in the SAME runs that
failed 155 — that is what pinned the fault to our build
([[project_conformance_control_leg_test_time]]).

Same disease as [[project_pw_webkit_base_lags_shipped_build]] (that one at the
*settings* level, this one at the *command* level).
