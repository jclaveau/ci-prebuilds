#!/usr/bin/env python3
"""Unit test for image-size-gate's verdict: `judge_image_size`, `build_step_key`,
`read_allowances` and `pair_layers_with_history`.

Exists because the gate is what stops a release, so its report is what someone reads
to find the layer that grew. The pnpm12.14 -> 12.16 gyp release grew 242.5 -> 277.8 MiB
compressed and nothing failed; the layers below are that release's, cut down.

Runs against no network -- every function under test takes layer lists, never a ref.
"""
import importlib.util
import pathlib
import sys

script_path = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "image-size-gate.py"
module_spec = importlib.util.spec_from_file_location("image_size_gate", script_path)
gate = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(gate)

MIB = 1024 * 1024

failures = 0
checks = 0


def check(label, got, want):
    global failures, checks
    checks += 1
    if got != want:
        print(f"FAIL: {label} — got {got!r}, wanted {want!r}", file=sys.stderr)
        failures += 1


def raises(label, call, want_message):
    try:
        call()
    except (ValueError, RuntimeError) as error:
        check(label, str(error), want_message)
        return
    check(label, "no exception", want_message)


# ------------------------------------------------------------ build_step_key

check("build-arg values dropped",
      gate.build_step_key('RUN |1 PNPM_VERSION=12.16.1 /bin/sh -c echo "Install PNPM"'),
      'RUN  /bin/sh -c echo "Install PNPM"')
check("multi-value build arg dropped",
      gate.build_step_key("RUN |2 DOCKER_GROUP_ID=113 DOCKER_HOST_GROUP_IDS=112 113 118 /bin/sh -c echo docker"),
      "RUN   /bin/sh -c echo docker")
check("first line only",
      gate.build_step_key("COPY /node/ /usr/local/ # buildkit\nsecond line"),
      "COPY /node/ /usr/local/ # buildkit")

# ------------------------------------------------------------ judge_image_size

check("first release",
      gate.judge_image_size("alpine-dood-node", [{"digest": "a", "size": 10 * MIB, "created_by": "COPY x"}],
                            None, None),
      (True, ["alpine-dood-node: 10.0 MiB, no published baseline, first release"]))

check("within the ratio",
      gate.judge_image_size("alpine-dood-node",
                            [{"digest": "a", "size": 104 * MIB, "created_by": "COPY x"}],
                            [{"digest": "b", "size": 100 * MIB, "created_by": "COPY x"}], None),
      (True, ["alpine-dood-node: 104.0 vs 100.0 MiB (1.040x), ceiling 105.0 MiB"]))

check("allowance raises the ceiling",
      gate.judge_image_size("alpine-dood-node",
                            [{"digest": "a", "size": 120 * MIB, "created_by": "COPY x"}],
                            [{"digest": "b", "size": 100 * MIB, "created_by": "COPY x"}], 125.0),
      (True, ["alpine-dood-node: 120.0 vs 100.0 MiB (1.200x), ceiling 105.0 MiB, allowance 125.0 MiB"]))

check("allowance under the ratio ceiling",
      gate.judge_image_size("alpine-dood-node",
                            [{"digest": "a", "size": 100 * MIB, "created_by": "COPY x"}],
                            [{"digest": "b", "size": 100 * MIB, "created_by": "COPY x"}], 102.0),
      (True, ["alpine-dood-node: 100.0 vs 100.0 MiB (1.000x), ceiling 105.0 MiB, allowance 102.0 MiB",
              "  allowance 102.0 MiB is under the ratio ceiling: delete its line"]))

check("pnpm12.14 -> 12.16 gyp release",
      gate.judge_image_size(
          "alpine-dood-pnpm-gyp",
          [
              {"digest": "c1", "size": 3 * MIB, "created_by": "ADD alpine-minirootfs.tar.gz / # buildkit"},
              {"digest": "c2", "size": int(49.8 * MIB),
               "created_by": 'RUN /bin/sh -c echo "OS-level tools, with mimalloc"'},
              {"digest": "c3", "size": int(54.1 * MIB), "created_by": "COPY /node/ /usr/local/ # buildkit"},
              {"digest": "c4", "size": int(52.7 * MIB),
               "created_by": 'RUN |1 PNPM_VERSION=12.16.1 /bin/sh -c echo "Install PNPM"'},
              {"digest": "c5", "size": 1024, "created_by": "RUN /bin/sh -c tiny"},
          ],
          [
              {"digest": "c1", "size": 3 * MIB, "created_by": "ADD alpine-minirootfs.tar.gz / # buildkit"},
              {"digest": "b2", "size": int(47.4 * MIB), "created_by": 'RUN /bin/sh -c echo "OS-level tools"'},
              {"digest": "b3", "size": 24 * MIB,
               "created_by": "RUN /bin/sh -c sudo apk add --no-cache nodejs npm"},
              {"digest": "b4", "size": int(50.3 * MIB),
               "created_by": 'RUN |1 PNPM_VERSION=12.14.0 /bin/sh -c echo "Install PNPM"'},
          ],
          None,
      ),
      (False, [
          "alpine-dood-pnpm-gyp: 159.6 vs 124.7 MiB (1.280x), ceiling 130.9 MiB",
          "  same step, grown:",
          '    +2.4 MiB (50.3 -> 52.7)  RUN |1 PNPM_VERSION=12.16.1 /bin/sh -c echo "Install PNPM"',
          "  steps only in the candidate:",
          "    54.1 MiB  COPY /node/ /usr/local/ # buildkit",
          '    49.8 MiB  RUN /bin/sh -c echo "OS-level tools, with mimalloc"',
          "  steps only in the baseline:",
          '    47.4 MiB  RUN /bin/sh -c echo "OS-level tools"',
          "    24.0 MiB  RUN /bin/sh -c sudo apk add --no-cache nodejs npm",
      ]))

# ------------------------------------------------------------ read_allowances

check("comments and blank lines",
      gate.read_allowances(["# header\n", "\n", "alpine-dood-node\t140\tICU data for fr Intl\n"]),
      {"alpine-dood-node": 140.0})
raises("missing reason",
       lambda: gate.read_allowances(["alpine-dood-node\t140\n"]),
       'allowance line 1 is not <image>\\t<max_mib>\\t<reason>: "alpine-dood-node\\t140"')

# ------------------------------------------------------ pair_layers_with_history

check("multi-arch index, empty layers skipped",
      gate.pair_layers_with_history(
          "ghcr.io/jclaveau/alpine-dood:sha-1",
          [
              {"Descriptor": {"platform": {"architecture": "amd64"}},
               "OCIManifest": {"layers": [{"digest": "l1", "size": 5}, {"digest": "l2", "size": 7}]}},
              {"Descriptor": {"platform": {"architecture": "unknown"}},
               "OCIManifest": {"layers": []}},
          ],
          {"linux/amd64": {"history": [
              {"created_by": "ADD rootfs"},
              {"created_by": "ENV PATH=/x", "empty_layer": True},
              {"created_by": "RUN apk add"},
          ]}},
      ),
      [{"digest": "l1", "size": 5, "created_by": "ADD rootfs"},
       {"digest": "l2", "size": 7, "created_by": "RUN apk add"}])
raises("history and layers disagree",
       lambda: gate.pair_layers_with_history(
           "ghcr.io/jclaveau/alpine-dood:sha-1",
           {"Descriptor": {}, "SchemaV2Manifest": {"layers": [{"digest": "l1", "size": 5}]}},
           {"history": []},
       ),
       '"ghcr.io/jclaveau/alpine-dood:sha-1": 1 layers but 0 non-empty history steps')

print(f"{checks - failures}/{checks} checks passed")
sys.exit(1 if failures else 0)
