#!/usr/bin/env bash
# Unit test for the PGO corpus patcher.
#
# The patcher rewrites five files it does not own — three in the Firefox tree,
# two in the fetched benchmark tarballs — by exact-text anchors. When an anchor
# drifts upstream the only thing standing between us and a silently unpatched
# corpus is the patcher's own "found N times, expected 1" check, so this test
# pins that: the anchors are copied here from upstream VERBATIM, independently
# of the patcher's copy, and a fixture that drifts by one character must fail
# the run rather than patch nothing and return 0.
#
# A corpus item that never starts closes its window at its own timeout and
# looks exactly like one that finished (PR #307), which is why a silent no-op
# here is the expensive failure and not a cosmetic one.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PATCHER="$ROOT/playwright/alpine-browsers/firefox/scripts/pgo-corpus-patches.py"

failures=0
checks=0
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Upstream text, verbatim, for every region the patcher anchors on.
# build/pgo/index.html is mozilla-central; Speedometer3 is vendored under
# third_party; JetStreamDriver.js and motionmark.js come from the pinned
# tarballs in versions.env.
seed_tree() {
  local dir="$1"
  mkdir -p "$dir/src/build/pgo" \
           "$dir/src/third_party/webkit/PerformanceTests/Speedometer3/resources" \
           "$dir/corpus/JetStream" \
           "$dir/corpus/motionmark/MotionMark/resources/runner"

  cat > "$dir/src/build/pgo/index.html" <<'FIXTURE'
<script>
  var defaultTimeout = 2 * 1000;
  var extendedTimeout = 2 * 60 * 1000;
  var superExtendedTimeout = 5 * 60 * 1000;
  var hasExtendedCorpus =
    new URLSearchParams(location.search).get("extendedCorpus") == "true";

  class Item {
    url;
    timeout;

    constructor(url, timeout = defaultTimeout) {
      this.url = url;
      this.timeout = timeout;
    }

    async run() {
      var subWindow = window.open(this.url);

      // Prevent the perf-reftest-singletons from calling alert()
      subWindow.tpRecordTime = function () {};

      // Wait until the timeout is finished
      await waitTimeout(this.timeout);

      subWindow.close();
    }
  }

  items.push(
    new Item("webkit/PerformanceTests/Speedometer/index.html", extendedTimeout),
    new Item(
      "http://localhost:8000/index.html?startAutomatically=true",
      extendedTimeout
    ),
    new Item(
      "webkit/PerformanceTests/webaudio/index.html?raptor&rendering-buffer-length=30",
      extendedTimeout
    )
  );

  if (hasExtendedCorpus) {
    items.push(
      new Item(
        "http://localhost:8001/index.html?startAutomatically=true&testIterationCount=3&worstCaseCount=1",
        superExtendedTimeout
      )
    );
  }
</script>
FIXTURE

  cat > "$dir/src/build/pgo/profileserver.py" <<'FIXTURE'
if __name__ == "__main__":
    if has_extended_corpus:
        js3_httpd = MozHttpd(
            port=8001,
            docroot=js3_dir,
        )
        js3_httpd.start(block=False)
        print("started JS3 server on port 8001")

    with TemporaryDirectory() as profilePath:
        profile = FirefoxProfile(
            profile=profilePath,
        )

        runner.start()
        ret = runner.wait()
        if ret:
            sp3_httpd.stop()
            if has_extended_corpus:
                js3_httpd.stop()
            httpd.stop()
            sys.exit(ret)

        ret = runner.wait()
        sp3_httpd.stop()
        if has_extended_corpus:
            js3_httpd.stop()
        httpd.stop()
FIXTURE

  cat > "$dir/src/third_party/webkit/PerformanceTests/Speedometer3/resources/main.mjs" <<'FIXTURE'
class MainBenchmarkClient {
    showResultsSummary() {
        this._showSection("#summary");
    }
}
FIXTURE

  cat > "$dir/corpus/JetStream/JetStreamDriver.js" <<'FIXTURE'
class Driver {
    async reportResults() {
        this.reportScoreToRunBenchmarkRunner();
        this.dumpJSONResultsIfNeeded();
        this.isDone = true;

        if (isInBrowser) {
            globalThis.dispatchEvent(new CustomEvent("JetStreamDone", {
                detail: this.resultsObject()
            }));
        }
    }
}
FIXTURE

  cat > "$dir/corpus/motionmark/MotionMark/resources/runner/motionmark.js" <<'FIXTURE'
window.benchmarkController = {
    showResults: function()
    {
        if (!this.addedKeyEvent) {
            document.addEventListener("keypress", this.handleKeyPress, false);
        }
    }
};

window.addEventListener("load", function() { benchmarkController.initialize(); });
FIXTURE
}

# $1 label, $2 expected rc, $3 expected output substring
run_patcher() {
  local label="$1" want_rc="$2" want_text="$3" dir="$4"
  local out got=0
  out=$(python3 "$PATCHER" "$dir/src" "$dir/corpus" 2>&1) || got=$?
  checks=$((checks + 1))
  if [ "$got" != "$want_rc" ]; then
    echo "FAIL: $label — exit $got, wanted $want_rc" >&2
    echo "$out" | sed 's/^/    /' >&2
    failures=$((failures + 1))
    return 1
  fi
  if ! printf '%s' "$out" | grep -qF "$want_text"; then
    echo "FAIL: $label — output does not contain '$want_text'" >&2
    echo "$out" | sed 's/^/    /' >&2
    failures=$((failures + 1))
    return 1
  fi
  return 0
}

# $1 label, $2 file, $3 substring that must be present after patching
expect_contains() {
  local label="$1" file="$2" want="$3"
  checks=$((checks + 1))
  if ! grep -qF "$want" "$file"; then
    echo "FAIL: $label — '$want' missing from $file" >&2
    failures=$((failures + 1))
  fi
}

# ---- a clean tree gets all eleven edits ------------------------------------
clean="$workdir/clean"
seed_tree "$clean"
run_patcher "clean tree patches" 0 "MotionMark completion: patched" "$clean"

index="$clean/src/build/pgo/index.html"
expect_contains "caps raised" "$index" "var defaultTimeout = 30 * 1000;"
expect_contains "tpRecordTime resolves instead of no-op" "$index" 'signalDone("tpRecordTime");'
expect_contains "cross-origin completion channel" "$index" 'event.data == "corpus-item-done"'
expect_contains "cross-origin channel is listened on" "$index" \
  'window.addEventListener("message", onMessage);'
expect_contains "per-item timing line" "$index" '"PGO corpus item: "'
expect_contains "MotionMark item added" "$index" "http://localhost:8002/index.html?autostart=true"

# Only the default-timeout items may treat load as completion — the long ones
# merely START at load, so reading it as "done" would cut each to a moment.
expect_contains "load is completion only for default-timeout items" "$index" \
  "this.endsOnLoad = timeout === defaultTimeout;"
# Speedometer3 is patched to report, so it gets the self-reporting cap while
# the two unpatched items keep the shorter one.
checks=$((checks + 1))
if ! grep -A1 -F '"http://localhost:8000/index.html?startAutomatically=true",' "$index" \
     | grep -qF "superExtendedTimeout"; then
  echo "FAIL: Speedometer3 was not moved to the self-reporting cap" >&2
  failures=$((failures + 1))
fi

server="$clean/src/build/pgo/profileserver.py"
expect_contains "MotionMark server" "$server" "port=8002,"
# Both exit paths stop it — the early return when profile initialization
# fails, and the normal one after the run.
checks=$((checks + 1))
stops=$(grep -cF "mm_httpd.stop()" "$server")
if [ "$stops" != 2 ]; then
  echo "FAIL: MotionMark server stopped on $stops of the 2 exit paths" >&2
  failures=$((failures + 1))
fi
expect_contains "dump reaches stdout" "$server" 'prefs["browser.dom.window.dump.enabled"] = True'

expect_contains "Speedometer3 reports completion" \
  "$clean/src/third_party/webkit/PerformanceTests/Speedometer3/resources/main.mjs" \
  'window.opener?.postMessage("corpus-item-done", "*");'
expect_contains "JetStream3 reports completion" \
  "$clean/corpus/JetStream/JetStreamDriver.js" \
  'globalThis.opener?.postMessage("corpus-item-done", "*");'
expect_contains "MotionMark autostarts from the URL" \
  "$clean/corpus/motionmark/MotionMark/resources/runner/motionmark.js" \
  'location.search).get("autostart") == "true"'

# ---- a second run changes nothing ------------------------------------------
before=$(find "$clean" -type f -exec sha256sum {} + | sort)
run_patcher "second run is a no-op" 0 "already patched" "$clean"
after=$(find "$clean" -type f -exec sha256sum {} + | sort)
checks=$((checks + 1))
if [ "$before" != "$after" ]; then
  echo "FAIL: second run rewrote files" >&2
  diff <(printf '%s' "$before") <(printf '%s' "$after") | sed 's/^/    /' >&2
  failures=$((failures + 1))
fi

# ---- a drifted anchor must fail loudly, in every file ----------------------
# One character each, the way an upstream reformat would arrive. A patcher that
# returned 0 here would ship a corpus missing that edit, and the profile run
# would look exactly as healthy as a complete one.
drift() {
  local label="$1" file="$2" from="$3" to="$4"
  local dir="$workdir/drift-$checks"
  seed_tree "$dir"
  sed -i "s|$from|$to|" "$dir/$file"
  run_patcher "drifted anchor fails: $label" 9 "expected 1" "$dir"
}

drift "index.html timeouts" src/build/pgo/index.html \
  "var defaultTimeout = 2 \* 1000;" "var defaultTimeout = 3 * 1000;"
drift "index.html Item.run" src/build/pgo/index.html \
  "var subWindow = window.open(this.url);" "let subWindow = window.open(this.url);"
drift "profileserver JS3 print" src/build/pgo/profileserver.py \
  'print("started JS3 server on port 8001")' 'print("started JS3 server on 8001")'
drift "Speedometer3 summary" \
  src/third_party/webkit/PerformanceTests/Speedometer3/resources/main.mjs \
  'this._showSection("#summary");' 'this._showSection("#results");'
drift "JetStream3 done event" corpus/JetStream/JetStreamDriver.js \
  'if (isInBrowser) {' 'if (isInBrowser === true) {'
drift "MotionMark bootstrap" \
  corpus/motionmark/MotionMark/resources/runner/motionmark.js \
  'benchmarkController.initialize(); });' 'benchmarkController.initialize() });'

# ---- an anchor that appears twice is just as ambiguous ---------------------
dup="$workdir/dup"
seed_tree "$dup"
cat >> "$dup/src/third_party/webkit/PerformanceTests/Speedometer3/resources/main.mjs" <<'FIXTURE'
class SecondClient {
    showResultsSummary() {
        this._showSection("#summary");
    }
}
FIXTURE
run_patcher "duplicated anchor fails" 9 "found 2 times" "$dup"

# ---- without a corpus dir, only the in-tree half runs ----------------------
notree="$workdir/notree"
seed_tree "$notree"
checks=$((checks + 1))
out=$(python3 "$PATCHER" "$notree/src" 2>&1) || {
  echo "FAIL: in-tree-only run exited non-zero" >&2
  echo "$out" | sed 's/^/    /' >&2
  failures=$((failures + 1))
}
if ! printf '%s' "$out" | grep -qF "JetStream3 + MotionMark skipped"; then
  echo "FAIL: in-tree-only run did not say it skipped the extended corpus" >&2
  failures=$((failures + 1))
fi
checks=$((checks + 1))
if grep -qF "localhost:8002" "$notree/src/build/pgo/index.html"; then
  echo "FAIL: in-tree-only run added the MotionMark item anyway" >&2
  failures=$((failures + 1))
fi

echo "pgo-corpus-patches: $((checks - failures))/$checks checks passed"
[ "$failures" -eq 0 ]
