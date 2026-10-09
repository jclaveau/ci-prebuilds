---
name: reference_famille_laptop_counting_box
description: famille laptop (ssh famille-laptop, i3-4005U, 3.8 GB) is a PMU-open box for local counted compares; hard-froze once at 3g, runs at LOCAL_MEMORY=2g
metadata:
  type: reference
---

`ssh famille-laptop` (192.168.1.20, user famille, key ~/.ssh/id_ed25519_famille,
BatchMode). Debian 13, i3-4005U Haswell 2c/4t, NO turbo, 3.8 GB RAM, docker
data-root /home/docker (78 GB free), perf 6.12, paranoid=-1, kptr_restrict=0,
uv in ~/.local/bin, sleep targets masked (2026-10-06).

- Repo copy at ~/ci-prebuilds: the auto-mode classifier refused my rsync as
  exfiltration until jean added two allow rules to .claude/settings.local.json
  (the exact `rsync -a --delete --exclude tmp/ --exclude node_modules/
  --exclude .agents/ ~/dev/ci-prebuilds/ famille-laptop:ci-prebuilds/` and
  `ssh famille-laptop *`). Now I sync myself after each commit. The ssh rule =
  root there (docker group): delete it + `sudo gpasswd -d famille docker` at campaign end.
- First run at LOCAL_MEMORY=3g hard-froze the laptop at probe start (journal
  lost the last minutes; no OOM line). 2g + logged-out desktop ran clean,
  peak swap 384 MB. A synced `tmp/mem-watch.log` logger is worth keeping on.
- Launch with `setsid -f … > log 2>&1 < /dev/null`; a plain nohup `&` kept ssh
  attached until the tool timeout.
- Counters multiplex (4 GP counters): trust task-clock and instructions,
  not cycles ratios, on this box.
- Always `LC_ALL=C` in remote scripts: fr_FR mawk misreads `0.8`, so an idle-wait loop spun 30 min at load 0.00 (see ~/.agents/reference_mawk_fr_locale_float_compare.md).
- An ssh login restarts the famille user manager: pipewire/wireplumber burst ~1 min; gate on 1-min load < 0.8 before counting.
- Preflight before every count: ~/.agents/feedback_count_instructions_whenever_possible.md.
- `tmp/count-arms.sh` (COUNT_BROWSER/COUNT_MEMORY; spec `name=repo:tag[:ENV=VAL]`): split image on the first TWO `:` fields; perf-real counters only for a candidate NAMED `official`, so other official-image candidates get wall only; report script takes 2 candidates at a time.
- Remove famille from the docker group when the campaign ends (suggested to jean at setup, root-equivalent).
