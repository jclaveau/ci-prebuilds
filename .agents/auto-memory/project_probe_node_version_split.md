---
name: project_probe_node_version_split
description: the perf probe's ubuntu arm runs node v22.23.2 while alpine and official both run v24.18.1, so eval_rtt splits into a fixable node-pin penalty on ubuntu and an unexplained residual on alpine
metadata:
  type: project
---

From the `runtime-perf` artifact of run 33052038241 (the probe records its own
`node` field per arm — read that, do not infer it from a Dockerfile or from
`docker run … node --version` on whichever image is handy):

```
alpine-chromium   v24.18.1     official-chromium  v24.18.1
alpine-firefox    v24.18.1     official-firefox   v24.18.1
ubuntu-chromium   v22.23.2     official-webkit    v24.18.1
ubuntu-firefox    v22.23.2
```

Only **our ubuntu image** is behind, from `node/Dockerfile`'s
`ARG NODE_VERSION=22.23.2`. Two parallel diagnoses disagreed about this because
each sampled a different subset — one checked alpine+official and generalised to
"both images ship v24.18.1", the other read the ubuntu artifact. The artifact is
the authority: it records what actually executed in the measured job.

**Consequence — `eval_rtt` is two problems, not one:**
- the **ubuntu** penalty (chromium 1.29, firefox 1.12) is the node pin, fixable
  with a one-line `ARG` bump and no browser rebuild;
- the **alpine** residual (chromium 1.15, firefox 1.06) is NOT a node-version
  effect, since alpine runs the same v24.18.1 as official. Still unexplained.

`eval_rtt` is 500 sequential `page.evaluate` round trips — node's stream/pipe and
event-loop path, multiplied by every Playwright action — so it is worth more
end-to-end than its percentage looks.

**How to apply:** the three-arm read only separates ENV from BUILD if you know
what actually differs between the arms; check the probe's recorded `node` (and
browser version) fields before charging a row to either column.
[[project_alpine_browser_perf_vs_glibc]], [[feedback_verify_ab_varied_the_variable]]
