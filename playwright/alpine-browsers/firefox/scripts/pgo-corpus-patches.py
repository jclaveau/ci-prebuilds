#!/usr/bin/env python3
"""Make the PGO profile run train on finished work instead of on a stopwatch.

Upstream's corpus opens each item in a window, waits a fixed 2 s / 2 min / 5 min,
and closes it. Nothing checks whether the item got that far. On an INSTRUMENTED
build -- several times slower than the one those numbers were picked for -- an
item that gets cut off mid-run is indistinguishable from one that finished, so
the profile silently covers less code than it looks like it does.

What this script changes, all at build time so no vendored copy drifts:

  build/pgo/index.html         Item.run races real completion signals against a
                               cap, and logs which one ended each item; adds the
                               MotionMark entry.
  build/pgo/profileserver.py   serves MotionMark on port 8002 and turns on the
                               prefs that put Item.run's log line on stdout.
  Speedometer3, JetStream3,    each posts "corpus-item-done" to its opener from
  MotionMark                   the same results path its own UI uses. They run on
                               their own ports, so postMessage is the only channel
                               that crosses the origin.

Idempotent: every edit asserts its anchor appears exactly once and skips a file
that already carries the replacement, so a resumed build re-runs it safely.

Usage: pgo-corpus-patches.py <firefox-src-dir> [<extended-corpus-dir>]
"""

import os
import sys


def replace_once(path, old, new, label):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    if new in text:
        print(f"  {label}: already patched")
        return

    count = text.count(old)
    if count != 1:
        print(
            f"ERROR: {label}: anchor found {count} times in {path}, expected 1",
            file=sys.stderr,
        )
        sys.exit(9)

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text.replace(old, new))
    print(f"  {label}: patched")


CONSTRUCTOR_OLD = """    url;
    timeout;

    constructor(url, timeout = defaultTimeout) {
      this.url = url;
      this.timeout = timeout;
    }"""

CONSTRUCTOR_NEW = """    url;
    timeout;
    endsOnLoad;

    constructor(url, timeout = defaultTimeout) {
      this.url = url;
      this.timeout = timeout;
      // A default-timeout item is a static page or a perf-reftest: all of its
      // work happens during load, so the load event means it finished. The
      // longer items are benchmarks that only START at load, and reading their
      // load as completion would cut each of them to a couple of seconds.
      this.endsOnLoad = timeout === defaultTimeout;
    }"""

ITEM_RUN_OLD = """    async run() {
      var subWindow = window.open(this.url);

      // Prevent the perf-reftest-singletons from calling alert()
      subWindow.tpRecordTime = function () {};

      // Wait until the timeout is finished
      await waitTimeout(this.timeout);

      subWindow.close();
    }"""

ITEM_RUN_NEW = """    async run() {
      var start = performance.now();
      var subWindow = window.open(this.url);

      var signalDone;
      var completed = new Promise(resolve => {
        signalDone = resolve;
      });

      // The ~70 talos perf-reftest singletons already announce completion
      // through tpRecordTime. This stub used to be a no-op, there only to keep
      // them from calling alert(), which threw the one signal they send away.
      subWindow.tpRecordTime = function () {
        signalDone("tpRecordTime");
      };

      // Speedometer3, JetStream3 and MotionMark each run on their own port
      // because they assume a root path, so this window can neither read their
      // DOM nor listen to their events. postMessage is the only channel that
      // crosses the origin; each of the three is patched to send it from the
      // same results path its own UI uses.
      var onMessage = function (event) {
        if (event.data == "corpus-item-done") {
          signalDone("postMessage");
        }
      };
      window.addEventListener("message", onMessage);

      // Same-origin static items get a third signal: one that never calls
      // tpRecordTime is done once it has loaded and sat idle for a moment.
      // A cross-origin window throws here and rides postMessage or the cap.
      try {
        if (this.endsOnLoad) {
          subWindow.addEventListener("load", function () {
            // The window opens on about:blank and navigates from there; only
            // the real document's load means the item ran.
            if (subWindow.location.href == "about:blank") {
              return;
            }
            waitTimeout(settleAfterLoad).then(() => signalDone("load"));
          });
        }
      } catch (e) {}

      var endedBy = await Promise.race([
        completed,
        waitTimeout(this.timeout).then(() => "timeout"),
      ]);

      window.removeEventListener("message", onMessage);
      subWindow.close();

      // One line per item, so a single run says which items signal, which ride
      // their cap, and how long each actually needs -- the numbers to size the
      // next set of caps against, instead of another dispatch to find out.
      dump(
        "PGO corpus item: " +
          Math.round(performance.now() - start) +
          " ms, ended by " +
          endedBy +
          ", " +
          this.url +
          "\\n"
      );
    }"""

TIMEOUTS_OLD = """  var defaultTimeout = 2 * 1000;
  var extendedTimeout = 2 * 60 * 1000;
  var superExtendedTimeout = 5 * 60 * 1000;"""

TIMEOUTS_NEW = """  // Caps, not durations. Every item now ends when it says it is done (see
  // Item.run) and reaches its cap only when no completion signal arrives, so
  // these are backstops sized for an INSTRUMENTED build -- several times
  // slower than the one upstream's 2 s / 2 min / 5 min were picked for.
  //
  // Three classes, by what signal the item can send:
  //   default          static pages and perf-reftests: tpRecordTime, or load
  //   extended         benchmarks we do not patch: no signal, they ride the cap
  //   superExtended    Speedometer3 and JetStream3: patched, they postMessage
  var defaultTimeout = 30 * 1000;
  var extendedTimeout = 5 * 60 * 1000;
  var superExtendedTimeout = 15 * 60 * 1000;
  var motionMarkTimeout = 12 * 60 * 1000;

  // How long a static page stays open after its load event, so the idle and GC
  // paths that follow a page load get profiled too.
  var settleAfterLoad = 2 * 1000;"""

EXTENDED_ITEMS_OLD = """    items.push(
      new Item(
        "http://localhost:8001/index.html?startAutomatically=true&testIterationCount=3&worstCaseCount=1",
        superExtendedTimeout
      )
    );"""

EXTENDED_ITEMS_NEW = """    items.push(
      new Item(
        "http://localhost:8001/index.html?startAutomatically=true&testIterationCount=3&worstCaseCount=1",
        superExtendedTimeout
      ),
      // MotionMark is the only item that trains the paint and composite paths
      // under sustained animation; the rest of the corpus is script, layout and
      // style. Mozilla pins the same revision for raptor but never feeds it to
      // PGO, because index.html's runner starts from a button -- patched below
      // to honour ?autostart.
      new Item("http://localhost:8002/index.html?autostart=true", motionMarkTimeout)
    );"""

LONG_ITEMS_OLD = """  items.push(
    new Item("webkit/PerformanceTests/Speedometer/index.html", extendedTimeout),
    new Item(
      "http://localhost:8000/index.html?startAutomatically=true",
      extendedTimeout
    ),"""

LONG_ITEMS_NEW = """  items.push(
    new Item("webkit/PerformanceTests/Speedometer/index.html", extendedTimeout),
    new Item(
      "http://localhost:8000/index.html?startAutomatically=true",
      superExtendedTimeout
    ),"""

MM_HTTPD_OLD = '''        js3_httpd.start(block=False)
        print("started JS3 server on port 8001")'''

MM_HTTPD_NEW = '''        js3_httpd.start(block=False)
        print("started JS3 server on port 8001")

        mm_dir = os.path.join(extended_corpus_dir, "motionmark", "MotionMark")

        if not os.path.exists(mm_dir):
            print(f"Error: MotionMark directory does not exist at {mm_dir}")
            sys.exit(1)

        # MotionMark must run in its own server for the same reason as the other
        # two: its resources resolve from the document root.
        mm_httpd = MozHttpd(
            port=8002,
            docroot=mm_dir,
        )
        mm_httpd.start(block=False)
        print("started MotionMark server on port 8002")'''

MM_STOP_INIT_OLD = """            sp3_httpd.stop()
            if has_extended_corpus:
                js3_httpd.stop()"""

MM_STOP_INIT_NEW = """            sp3_httpd.stop()
            if has_extended_corpus:
                js3_httpd.stop()
                mm_httpd.stop()"""

MM_STOP_RUN_OLD = """        sp3_httpd.stop()
        if has_extended_corpus:
            js3_httpd.stop()"""

MM_STOP_RUN_NEW = """        sp3_httpd.stop()
        if has_extended_corpus:
            js3_httpd.stop()
            mm_httpd.stop()"""

DUMP_PREFS_OLD = """        profile = FirefoxProfile("""

DUMP_PREFS_NEW = """        # Item.run writes one timing line per corpus item to the browser's
        # stdout, which the runner forwards into the build log. Without these
        # the corpus runs silently and a cap that fired early -- the failure
        # this whole change exists to catch -- looks like a clean finish.
        prefs["browser.dom.window.dump.enabled"] = True
        prefs["devtools.console.stdout.content"] = True

        profile = FirefoxProfile("""

SP3_OLD = """    showResultsSummary() {
        this._showSection("#summary");"""

SP3_NEW = """    showResultsSummary() {
        // Tell the PGO corpus the run is over. Both terminal paths reach here,
        // didFinishLastIteration and handleError, so one anchor covers a clean
        // finish and a crashed one.
        window.opener?.postMessage("corpus-item-done", "*");
        this._showSection("#summary");"""

JS3_OLD = """        if (isInBrowser) {
            globalThis.dispatchEvent(new CustomEvent("JetStreamDone", {
                detail: this.resultsObject()
            }));
        }"""

JS3_NEW = """        if (isInBrowser) {
            globalThis.dispatchEvent(new CustomEvent("JetStreamDone", {
                detail: this.resultsObject()
            }));
            // Tell the PGO corpus the run is over; it is on another origin and
            // cannot hear the event above.
            globalThis.opener?.postMessage("corpus-item-done", "*");
        }"""

MM_AUTOSTART_OLD = """window.addEventListener("load", function() { benchmarkController.initialize(); });"""

MM_AUTOSTART_NEW = """window.addEventListener("load", function() {
    // ?autostart runs the same suite set and parameters the start button does.
    // developer.html already accepts a URL-encoded run, but only one test per
    // suite and with every parameter spelled out; index.html is the real
    // benchmark, and this is the one thing it was missing for automation.
    benchmarkController.initialize().then(function() {
        if (new URLSearchParams(location.search).get("autostart") == "true") {
            benchmarkController.startBenchmark();
        }
    });
});"""

MM_DONE_OLD = """    showResults: function()
    {
        if (!this.addedKeyEvent) {"""

MM_DONE_NEW = """    showResults: function()
    {
        // Tell the PGO corpus the run is over.
        window.opener?.postMessage("corpus-item-done", "*");

        if (!this.addedKeyEvent) {"""


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        sys.exit(2)

    src = sys.argv[1]
    corpus = sys.argv[2] if len(sys.argv) > 2 else None

    print("===== PGO corpus patches: firefox tree =====")
    index_html = os.path.join(src, "build", "pgo", "index.html")
    replace_once(index_html, TIMEOUTS_OLD, TIMEOUTS_NEW, "index.html timeouts")
    replace_once(index_html, CONSTRUCTOR_OLD, CONSTRUCTOR_NEW, "index.html Item.endsOnLoad")
    replace_once(index_html, ITEM_RUN_OLD, ITEM_RUN_NEW, "index.html Item.run")
    replace_once(index_html, LONG_ITEMS_OLD, LONG_ITEMS_NEW, "index.html Speedometer3 cap")

    profileserver = os.path.join(src, "build", "pgo", "profileserver.py")
    replace_once(profileserver, DUMP_PREFS_OLD, DUMP_PREFS_NEW, "profileserver dump prefs")

    sp3 = os.path.join(
        src, "third_party", "webkit", "PerformanceTests", "Speedometer3",
        "resources", "main.mjs",
    )
    replace_once(sp3, SP3_OLD, SP3_NEW, "Speedometer3 completion")

    if not corpus:
        print("  (no extended corpus dir given; JetStream3 + MotionMark skipped)")
        return

    print("===== PGO corpus patches: extended corpus =====")
    replace_once(index_html, EXTENDED_ITEMS_OLD, EXTENDED_ITEMS_NEW, "index.html MotionMark item")
    replace_once(profileserver, MM_HTTPD_OLD, MM_HTTPD_NEW, "profileserver MotionMark server")
    replace_once(profileserver, MM_STOP_INIT_OLD, MM_STOP_INIT_NEW, "profileserver MotionMark stop (init)")
    replace_once(profileserver, MM_STOP_RUN_OLD, MM_STOP_RUN_NEW, "profileserver MotionMark stop (run)")

    js3 = os.path.join(corpus, "JetStream", "JetStreamDriver.js")
    replace_once(js3, JS3_OLD, JS3_NEW, "JetStream3 completion")

    mm = os.path.join(corpus, "motionmark", "MotionMark", "resources", "runner", "motionmark.js")
    replace_once(mm, MM_AUTOSTART_OLD, MM_AUTOSTART_NEW, "MotionMark autostart")
    replace_once(mm, MM_DONE_OLD, MM_DONE_NEW, "MotionMark completion")


if __name__ == "__main__":
    main()
