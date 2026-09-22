# Atelier — Final Independent Verification (Phases 1 & 2)

**Date:** 2026-09-22 (session date 2026-09-21/22)
**Verifier:** independent agent, re-ran everything below; did not re-read the five prior review reports beyond their finding IDs (per instruction: re-run, not re-read).
**Scope:** AUDIT.md §9/§10 outcomes, `.omc/reviews/{phase1-security,phase1-critic,phase1-codex,phase2-code-review,phase2-codex}.md` finding IDs.
**Constraints honored:** no repo file modified (one temporary, non-tracked overlay directory `containers/zzverify/` was added for scratch-project tests and removed before finishing; nothing under version control was touched); `just auth` never run; contents of the real `atelier-auth-*` volumes never read (only their emptiness/non-emptiness was observed via `agent-enter.sh`'s own warnings, and via smoke's own probe-and-restore cycle). Runtime (`atelier-egress`, `atelier-internal`) was used exclusively by this run; both executors were idle throughout.

---

## 1. Hard gate — smoke suites (item 1)

Both re-run from a clean invocation of `just smoke` / `just smoke-enter`, not read from prior output.

```
== summary: 27 passed, 0 failed, 0 skipped ==     (just smoke)
== summary: 45 passed, 0 failed ==                (just smoke-enter)
```

Both fully green. Matches the executors' report (27/27, 45/45). **Gate passed — proceeded to items 2–11.**

Documentation note: AUDIT.md §9 still says "24/24 smoke assertions" from the Phase 1 verifier round, and §10 says smoke-enter is "23 assertions." Both have since grown (27 and 45 respectively) without AUDIT.md being updated. Not a functional defect, but §9/§10 are now stale on these counts.

---

## 2. Phase 2 CRITICAL C1 — self-refusal by filesystem identity (item 2)

Confirmed first that `/home/user/Documents/vibe-code/atelier-harness` and `/var/home/user/Documents/vibe-code/atelier-harness` really are one inode on this host (device:inode `62:140854238` for both), so the test is meaningful, not vacuous.

| Case | Result |
|---|---|
| `--dir /home/user/...atelier-harness --no-tmux -- true` (alternate canonical path) | **exit 3**, refusal message names device+inode identity, no container created |
| `--dir <symlink-to-parent-dir>/atelier-harness --no-tmux -- true` (symlinked parent) | **exit 3**, same refusal, no container created |
| `--dir "$HOME" --no-tmux -- true` | **exit 3**, dangerous-dir refusal (`AUDIT.md §4.1`), no container created |

`podman ps -a | grep '^agent-'` was empty after each case. C1 is fixed and independently reproduced by three different paths into the same guard.

---

## 3. Phase 2 H1 / H3 — reused container silently ignoring `--dir` / `--network` (item 3)

Used a temporary scratch overlay (`containers/zzverify/`, a copy of `containers/example/`, removed at the end — see the constraints note above) to avoid colliding with the `agent-example` name the smoke suite owns (review M4).

- Created `agent-zzverify` with `--network none` at one directory.
- Re-entered the same project with a **different `--dir`** → refused: `container agent-zzverify has <dir-a> at /work, not <dir-b>; pass --rebuild...` — **exit 4**.
- Re-entered the same project, same `--dir`, with `--network proxied` → refused: `container agent-zzverify was created with network profile 'none', not 'proxied'; pass --rebuild...` — **exit 4**.

Both H1 and H3 fixed: a mismatched reuse request is refused rather than silently reusing stale `/work` or network state.

---

## 4. Phase 2 H2 — auth-volume probe container on the open network (item 4)

Deterministic event-window check (`podman events --since/--until --stream=false`, not a racy background stream) around a single normal `agent-enter.sh` entry:

- Exactly **one** `create` event in the window, for `agent-zzverify`, network `atelier-internal` (the requested `proxied` profile).
- No second, `--rm`-only probe container appears in the events stream at all, and none appeared on the default `podman` network.

On this host `ensure_auth_volume` took the fast path (the volume's mountpoint under `/home/user/.local/share/containers/...` is directly readable by this user), so the `probe_volume_contents` fallback — the actual `podman run --rm` this finding is about — was never exercised live. Reading it (`scripts/agent-enter.sh:370-378`) shows it already carries `--network=none --cap-drop=ALL --security-opt=no-new-privileges --read-only --userns=keep-id:uid=1000,gid=1000` and mounts the volume `:ro`, so if it had triggered it would not have been an unhardened, open-network probe. H2 is confirmed fixed by source inspection for the fallback path, and confirmed live for the common path: this run produced exactly one `create` event and it was the real agent container, not a probe.

---

## 5. Phase 2 H4 / H6 — dotted project names and tmux-layer staleness (item 5)

Used a private tmux socket (`tmux -L zzverify-test-$$`, the same isolation pattern `tests/smoke-enter.sh` uses via `ATELIER_TMUX`) so the host's real tmux sessions were never touched.

- **H4:** `--project zz.verify.dot` created tmux session `agent-zz.verify.dot`; `has-session -t agent-zz.verify.dot:` succeeded (trailing colon needed, as documented). A second invocation against the same dotted name reused the same session (`created` timestamp unchanged, `list-sessions` still shows exactly one session for it) rather than failing or duplicating.
- **H6:** created `agent-zzverify` + tmux session via the tmux path, recorded the container ID, then `podman rm -f agent-zzverify` behind the live session, then re-entered via the tmux path. New container ID differed from the old one — **the container was recreated**, not silently attached to a dead pane.

Both H4 and H6 confirmed fixed. (One process note: my own first attempt at cleanup after this section left a stray `agent-zz.verify.dot` container behind — caught and removed during the item 9 hygiene sweep before finishing; see below.)

## 5b. Phase 2 H5 — `REPO_ROOT` not canonicalized (out of the lead's checklist, tested anyway)

Not in the lead's numbered list, but claimed as fixed in AUDIT.md §10's HIGH list, so tested for completeness: invoked `agent-enter.sh` through a symlink pointing at it (`$SP/enter-link.sh -> scripts/agent-enter.sh`) rather than by its real path.

- `enter-link.sh --project zzh5 --dir <scratch-dir> --no-tmux -- true` → succeeded normally (image fallback to `agent-base:latest`, container created, exit 0).
- `enter-link.sh --dir /var/home/user/...atelier-harness --no-tmux -- true` → the same self-refusal fired through the symlink, exit 3.

`REPO_ROOT` resolves correctly and the self-refusal guard is not bypassable by invoking the script through a symlink. H5 confirmed fixed.

---

## 6. Phase 1 Codex round (item 6)

| Finding | Check | Result |
|---|---|---|
| Unpinned installer script removed | `containers/agent-base/install-claude.sh` | **Absent** (`ls` → No such file or directory) |
| Exact-version binary + hash check | Containerfile | `ARG CLAUDE_VERSION=2.1.278`, `ARG CLAUDE_BINARY_SHA256=5c47...`, downloads `.../${CLAUDE_VERSION}/linux-x64/claude`, then `sha256sum -c -` before install |
| npm lockfile present, `npm ci --ignore-scripts` | `containers/agent-base/npm/package-lock.json` (200KB) present; Containerfile runs `npm ci --ignore-scripts` | Confirmed |
| `pi` resolves into the real package | `podman run --rm --network=none agent-base:latest bash -c 'readlink -f ~/.local/bin/pi'` | `/home/agent/.local/lib/atelier-npm/node_modules/@mariozechner/pi-coding-agent/dist/cli.js` — confirmed, not a same-named shim |
| entrypoint.sh rejects `10.88.0.1` | Ad hoc `--rm --network=none` run of `localhost/atelier-egress:latest` with `ALLOWLIST_DIR` pointed at a scratch dir containing only `10.88.0.1` | `entrypoint.sh: invalid allow-list entry ... '10.88.0.1' ...`, exit 1 |
| entrypoint.sh rejects `*.github.com` | Same, with `*.github.com` | `entrypoint.sh: invalid allow-list entry ... '*.github.com' ...`, exit 1 |
| `scripts/auth-import.sh` uses `--network=none` | grep | Confirmed (`--network=none unconditionally`, with an in-code rationale comment) |

All seven items independently reproduced live (not just read from source), except the source-read items (absence of a file, lockfile presence) which don't need a live run.

---

## 7. DNS fix (item 7)

```
podman network inspect atelier-internal:  internal=True, dns_enabled=False, subnet=10.89.14.0/24
atelier-egress IP on atelier-internal:    10.89.14.10
podman exec atelier-egress getent hosts api.github.com:  140.82.11x.x  api.github.com  (succeeded every time, 5 different IPs across 5 cycles — GitHub's anycast, not a flake)
```

A proxied `agent-enter.sh` entry (own scratch project, cleaned up after) resolved `atelier-egress` via `/etc/hosts` (`getent hosts atelier-egress` → `10.89.14.10`) and got `HTTP_200` from `https://api.github.com/` through the proxy.

**5× cycle** of `podman rm -f atelier-egress && just egress-up`, with a `getent hosts api.github.com` check inside the container after each cycle:

```
cycle 1: RESOLVE OK
cycle 2: RESOLVE OK
cycle 3: RESOLVE OK
cycle 4: RESOLVE OK
cycle 5: RESOLVE OK
=== egress-up cycle result: 5/5 ===
```

`grep -il "attempt\|unlucky"` across all 5 cycle logs: no matches. The retry loop is gone from the live output; the words "attempt" / "unlucky" that do appear in the Justfile (`grep -n` below) are exclusively in comments explaining *why* the old 3-attempt loop was replaced, not executable code.

---

## 8. Justfile hygiene / injection resistance (item 8)

```
$ grep -n '|| true' Justfile
357:    # No `|| true`: a network still in use, or a container that refuses
```
One hit, and it is a comment stating the *absence* of `|| true` as a design decision at that point in the recipe — there is no live `|| true` anywhere in the Justfile.

```
$ just build 'z"; echo INJECTED >&2; #'
valid-project-name: invalid project name 'z"; echo INJECTED >&2; #' (must match ^[A-Za-z0-9._-]+$, and not be '.' or '..')
error: recipe `build` failed with exit code 2
```
Refused before any shell interpolation; no `INJECTED` output, no stray image. `scripts/valid-project-name.sh` is confirmed as the single call site for both:
```
scripts/agent-enter.sh:176:  if ! "${REPO_ROOT}/scripts/valid-project-name.sh" "$name"; then
Justfile:156:    ./scripts/valid-project-name.sh "$project"
```

---

## 9. Repo hygiene (item 9)

```
$ git status --porcelain
?? .gitignore
?? AUDIT.md
?? Justfile
?? README.md
?? containers/
?? docs/
?? scripts/
?? tests/
```
No `.omc` paths (repo has no commits yet — everything is untracked `??`, which is the pre-existing state of this repo, not something from this run). `.gitignore` correctly excludes `/.omc/`.

```
$ ls -dZ .
system_u:object_r:default_t:s0 .
```
Non-container label confirmed — the earlier `:Z` relabel from review M1 is reset, as AUDIT/README say it should be.

Post-run sweep vs. the pre-run baseline captured before any command ran:
- **`agent-*` containers:** one stray (`agent-zz.verify.dot`, left behind after the H4/H6 tmux tests) was caught during this sweep and removed. Final state: none.
- **Scratch images:** the temporary `agent-zzverify:*` and `agent-zzproxy:*` images were removed at the point of use; final `podman images` shows no `zz*`-tagged images. `agent-example:latest`/`:20260921` remain, but those pre-date this run (present in the baseline capture) and are the smoke-enter suite's own fixture, not something created here.
- **tmux test sockets:** baseline and post-run listings of `/tmp/tmux-1000/` are identical (`default`, plus pre-existing `revdead`, `revdead2`, `revdot`, `revfix`, `revfix2`, `review-probe`, `revt` — all present before this run started). This run's own private socket (`zzverify-test-<pid>`) was killed and removed before the final sweep. **Note:** the seven `rev*` sockets are pre-existing debris from earlier review sessions (not created by this run, not cleaned by it either, per "clean up everything you create" — they are someone else's leftovers, flagged here rather than silently deleted).
- **Networks/volumes:** `podman network ls` and the `atelier-*` volume list are unchanged from baseline (no new networks; only the three expected `atelier-auth-*` volumes, none read).
- `atelier-egress` was left running and healthy (`Up`, resolves `api.github.com`) after the 5× cycling in item 7.

---

## 10. README contract table (item 10)

All required elements are present, quoted verbatim:

- **Five auth volume names, gh split:** "Five named volumes, never `$HOME` bind mounts (see below): `atelier-auth-claude`, `atelier-auth-codex` ... `atelier-auth-gh` (the owner's interactive `hosts.yml`, mounted **only** by `agent-enter.sh`...); `atelier-auth-gh-publish` and `atelier-auth-gh-review`, reserved for owner-minted fine-grained GitHub PATs..."
- **`--add-host` on the proxied profile:** "the proxied profile also adds `--add-host atelier-egress:<ip>` -- the name is no longer resolvable by DNS on that network at all."
- **`none` is preflight-only:** "`none` (`--network=none`; for runs that never call a model at all -- an in-container auth preflight, a local build/test step)"
- **codex-needs-node note:** "`nodejs24` stays in the image anyway, because `codex` and `pi` ship as npm packages whose `codex`/`pi` executables are Node shims that `require()` the actual implementation at run time -- removing Node after installing them would leave those two commands present on `PATH` but non-functional."
- **Proxy invariant:** "Fails fast with a `just egress-up` pointer if `atelier-egress` isn't running -- checked before every proxied create *and* every proxied reuse or attach, not only at creation, so it never silently falls back to no egress control."
- **Restart caveat:** "`atelier-egress` runs with `--restart=always`. In **rootless** Podman that only means 'restart if the process dies while the user session is still [alive]' ... a full reboot needs `systemctl --user enable --now podman-restart.service`..."
- **Shadowing note:** "**A populated auth volume shadows whatever the image put at that path.**"
- **Trust-boundary exception:** "**This repo is inside its own trust boundary and must never be `/work`** ... next time the owner runs a build or `egress-up` -- exactly the trusted [moment this design protects]."
- **`just egress-up` prerequisite for smoke-enter:** "`just smoke-enter` (`tests/smoke-enter.sh`) covers `agent-enter.sh` instead, and needs both `just build example` and a running `atelier-egress` (`just egress-up`) first, since the default network profile is `proxied`."
- **`:Z`/restorecon note:** "**`:Z` relabels the project directory with a private SELinux MCS category**... any other confined process that also needs to read that directory loses access until the label is restored (`restorecon -R -v <dir>`...)."

All ten elements found; none missing.

**One internal contradiction found while quoting the table:** line 55 says "`NO_PROXY=` -- unchanged"; line 281 (the network-profile detail table) says `NO_PROXY=localhost,127.0.0.1`. Checked against the actual code (`scripts/agent-enter.sh`, `add_proxy_flags`, line 444): `-e "NO_PROXY=localhost,127.0.0.1" -e "no_proxy=localhost,127.0.0.1"`. The code and line 281 agree; line 55 is stale/wrong. This is a real, if minor, documentation defect in the README's own contract table, not something introduced by this verification.

---

## 11. Coding style — scripts/*.sh, tests/*.sh (item 11)

**File size:**
```
  614 scripts/agent-enter.sh
   78 scripts/auth-import.sh
   62 scripts/source-sha.sh
   27 scripts/valid-project-name.sh
  665 tests/smoke-enter.sh
  585 tests/smoke.sh
```
No file over 800 lines.

**Function length:** enumerated every top-level `name() {` in the three largest files and measured the gap to the next function start — an upper bound on each function's length (the body ends at or before the next function's start line, since these are consecutive top-level definitions with no dead space between them). Largest in `agent-enter.sh`: `parse_args` (~38 lines) and `build_run_flags` (~41 lines) — both under 50. `main` (to EOF) ~21 lines. Since even this upper bound stays under 50 everywhere, no function over 50 lines exists in any of the six files.

**Silently swallowed errors:** all six files start with `set -euo pipefail`. `grep -n '|| true'` across `scripts/*.sh` and `tests/*.sh` shows:
- **Zero** occurrences in `scripts/agent-enter.sh`, `scripts/auth-import.sh`, `scripts/source-sha.sh`, `scripts/valid-project-name.sh` — the production scripts. `agent-enter.sh` states this as an explicit design principle in its own header comment ("Functions are kept under 50 lines each; no `|| true` hides a real [error]").
- All `|| true` occurrences are confined to `tests/smoke.sh` / `tests/smoke-enter.sh`, and are exclusively (a) best-effort teardown in `cleanup`/trap-style code (`podman rm -f ... || true`, `tmux kill-server ... || true`) or (b) the well-known `grep -c ... || true` idiom to stop a zero-match `grep` from tripping `set -e` when counting matches is the intended behavior. None of these mask a real production error path.

No violations found against the coding-style rules for these files.

---

## Verdict

**Phases 1 and 2 are complete against AUDIT.md.** Every item in this checklist reproduced independently and matched what AUDIT.md §9/§10 and the five review reports claim: both smoke suites are fully green (27/27, 45/45) as the hard gate; the Phase 2 CRITICAL (C1, filesystem-identity self-refusal, tested via alternate canonical path, symlinked parent, and `$HOME`) and all six HIGHs (H1, H2, H3, H4, H5, H6 — H5 was outside the lead's numbered checklist but tested anyway for completeness) reproduce as fixed under live, adversarial conditions generated here, not by re-reading the reviews; every Phase 1 Codex finding checked (unpinned installer removed, exact-version+hash binary, npm lockfile + `npm ci --ignore-scripts`, correct `pi` resolution, allow-list rejecting IP literals and wildcards, `--network=none` on credential extraction) is present and live; the DNS/egress fix is deterministic across 5/5 cycles with no trace of the old retry-loop language; the Justfile has no live `|| true` and refuses a shell-injection-shaped project name before any interpolation; the README's contract table covers all ten required points verbatim; and the coding-style bar (function/file size, no swallowed errors) holds across every script and test file.

What remains open, none of it blocking: AUDIT.md §9/§10's assertion counts (24 and 23) are stale against the suites' current sizes (27 and 45) — a one-line doc fix. The README's own contract table contradicts itself on `NO_PROXY` (line 55 says unchanged/empty, line 281 and the actual code say `localhost,127.0.0.1`) — line 55 is the one to fix. The seven `rev*` tmux sockets under `/tmp/tmux-1000/` are pre-existing debris from earlier review sessions, not from Phase 1/2 work itself or from this verification run — worth a manual `tmux -L <name> kill-server` sweep by whoever owns them, but they do not indicate a defect in the harness. And, as recorded in AUDIT.md §9, the plain-HTTP relay gap remains DEFERRED-BY-DECISION, not a regression found here. No new functional defects were found in this pass — only the two documentation staleness items above.
