---
name: wk-loader-only-probe
description: `MiniBrowser --version` prices startup with no browsing in it, and ld.so --list splits the loader from static init
metadata:
  type: project
---

`MiniBrowser --version` loads the whole closure, prints a version string and
exits. It is the fast instrument for anything `launch`-shaped: seconds per
reading instead of a probe run, and the browser library never even appears in
its profile.

- `./MiniBrowser --version` — loader + static init + main
- `/lib/ld-musl-x86_64.so.1 --list ./MiniBrowser` — loader only, no
  constructors, no main. glibc's is `ld-linux-x86-64.so.2 --list`.

Ours read 69 ms against Playwright's 41 ms on a hosted runner, with the
dynamic linker at 14.0% of all samples versus 11.4% + 0.9% — and per iteration
(435 loads to their 730) musl doing about twice the work. Locally the split is
101 ms loader of 147 ms total, so two thirds is over before our code runs.

Two traps:
- **Layout.** Ours is flat, RPATH=`$ORIGIN`; Playwright ships `bin/` + `lib/`
  and puts a **shell wrapper** where we put the ELF, so `ldd ./MiniBrowser`
  answers "not a dynamic executable" and an audit silently reports a
  one-object closure. Prefer `bin/MiniBrowser` when it exists.
- **In musl, `ld-musl-x86_64.so.1` IS libc**, so its profile share must be
  compared to glibc's `ld-linux` **plus** `libc.so.6`.

Lives as `wk-perf-record.yml`'s `loader` kernel and the loader step of
`wk-lag-diagnostics.yml`; `playwright/bench/closure-reloc-audit.sh` totals the
closure's relocations beside it. See
[[project_wk_launch_is_mesa_in_the_closure]] for what it found.
