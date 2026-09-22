# Phase 2 code review — entry mechanism

Reviewer: `phase2-review` (Opus). Date: 2026-09-21.
Scope: `scripts/agent-enter.sh`, `scripts/source-sha.sh`, `tests/smoke-enter.sh`,
`Justfile` (`build <project>`, `smoke-enter`, `build-egress` allow-list union),
`containers/example/*`, README "Overlay convention" and "Entering a project".
Out of scope: `containers/agent-base`, egress-proxy internals (another executor
is mid-change there).
Spec: AUDIT.md §3.1, §3.2, §4.1–§4.4, §5, §7; `docs/prp/atelier-prp.md` §5.

No files were modified. Every finding below was reproduced on this host unless
marked "by inspection".

**Versions reviewed.** `scripts/agent-enter.sh` (mtime 22:03, 398 lines) and
`scripts/source-sha.sh` (21:36, 62 lines) did not change during the review, so
C1 and H1–H5 are against current code. `tests/smoke-enter.sh` was edited at
22:36 *while my second smoke run was executing* (288 → 321 lines) and the
`Justfile` at 22:28. I re-read both afterwards: the test's only change is a new
injection section at `:99-130` (assessed below, it is good), so the MEDIUM
findings hold with line numbers shifted by +33 — quoted here against the
**current** 321-line file. The Justfile's `build`, `build-egress` and
`smoke-enter` recipes are byte-identical to what I reviewed; all of its growth
is in `egress-up`, which is out of scope.

## Severity counts

| Severity | Count |
|---|---|
| CRITICAL | 1 |
| HIGH | 6 |
| MEDIUM | 9 |
| LOW | 5 |

Findings are ordered by topic within each severity band, not by number, so
related ones sit together: H4 and H6 are both the tmux layer, H1/H3 are both
container reuse, M2 and M9 are both SELinux relabelling.

## Smoke test run

**Result: `== summary: 25 passed, 0 failed ==`** (third attempt; the first two
were lost to an environmental problem, documented below).

```
== agent-enter.sh smoke test ==
podman: distrobox-host-exec podman
project dir: /tmp/tmp.ZfsdEqRG85/project-701868

PASS: image agent-example:latest exists locally
PASS: self-refusal: agent-enter.sh refuses this repo's directory as --dir (exit 3)
PASS: self-refusal: --allow-self permits this repo's directory as --dir
PASS: just build refuses an injection-shaped project name without executing it
PASS: agent-enter.sh refuses an injection-shaped project name (exit 2)
PASS: container agent-example was created
PASS: CapDrop is set and effective CapBnd is all zeros (0000000000000000)
PASS: NoNewPrivs is 1
PASS: userns keep-id: uid 1000 in container, IDMappings show the 1000:0:1 keep-id entry
PASS: PidsLimit is 2048
PASS: --init is set
PASS: mounts are exactly /work plus the three auth volumes, nothing else
PASS: network profile 'proxied' (default) joins atelier-internal
PASS: proxied profile sets HTTPS_PROXY/https_proxy to atelier-egress:3128
PASS: jq --version works (overlay tool present, got: jq-1.8.1)
PASS: a second invocation reuses the same container (id unchanged)
PASS: a command after -- that exits 0 propagates exit code 0
PASS: a command after -- that exits 42 propagates exit code 42
PASS: staleness warning appears when the image label doesn't match its current inputs
PASS: staleness warning is absent once the image is rebuilt correctly
PASS: --rebuild produces a new container id
PASS: --network=none: DNS fails and a raw-IP curl to 1.1.1.1 fails with exit 7 (no route)
PASS: --network=none: no proxy env injected
PASS: tmux layer creates a session named agent-example
PASS: a second invocation attaches to the existing tmux session rather than creating a second one

== summary: 25 passed, 0 failed ==
```

**A green suite alongside a CRITICAL finding is the central point of this
review, not a contradiction.** Every finding below is about behaviour the suite
does not exercise, and the 25 passes are consistent with all of them:

- The self-refusal assertion passes because it compares the *identical* path
  string; C1 is about a second path to the same inode.
- "a second invocation reuses the same container" passes because it re-enters
  with the *same* `--dir`; H1 is about a different one.
- The `proxied` and `none` profiles are each asserted only on a freshly created
  container; H3 is about switching profiles on an existing one.
- The tmux assertions use project `example`, which has no dot (H4), and never
  remove the container behind a live session (H6).
- "staleness warning is absent once rebuilt" passed non-vacuously *this* time
  because `enter` happened to succeed; the `|| true` that makes it pass on any
  failure is still there (M3).

So the suite is green and the entry mechanism still has a security control that
fails open. That gap is what M3 and M8 are for.

**The first two attempts**, for the record, both aborted before printing a
summary line:

```
== agent-enter.sh smoke test ==
podman: distrobox-host-exec podman
project dir: /tmp/tmp.IRmdSvssQa/project-500495

PASS: image agent-example:latest exists locally
PASS: self-refusal: agent-enter.sh refuses this repo's directory as --dir (exit 3)
PASS: self-refusal: --allow-self permits this repo's directory as --dir
error: recipe `smoke-enter` failed on line 195 with exit code 1
```

That run died at `tests/smoke-enter.sh:100` under `set -e`. Two separate causes:

1. **Environmental.** The `atelier-egress` container did not exist at the time
   (only an unnamed container `reverent_varahamihira` from
   `localhost/atelier-egress:latest` was running), so `agent-enter.sh`'s proxied
   preflight correctly exited 1 with `--network=proxied requires atelier-egress
   to be running`. That is the code under review behaving as specified. I did
   not run `just egress-up` to fix it, because that would have rebuilt
   `atelier-egress:latest` from proxy sources another executor was editing; I
   messaged `phase2-build` instead, who brought the proxy back up and confirmed
   the environment was clear. The third run then passed.
2. **A real defect**, filed as M6 below: an unguarded command failure kills the
   script with no summary and no `FAIL:` line, so a hard failure is reported
   less clearly than a soft one.

**Second attempt**, after `atelier-egress` came back up:

```
== agent-enter.sh smoke test ==
podman: distrobox-host-exec podman
project dir: /tmp/tmp.Ekm2Pv1o5I/project-592715

PASS: image agent-example:latest exists locally
PASS: self-refusal: agent-enter.sh refuses this repo's directory as --dir (exit 3)
FAIL: self-refusal: --allow-self permits this repo's directory as --dir (got: agent-enter: no containers/atelier-harness/Containerfile found; using agent-base:latest
agent-enter: --network=proxied requires atelier-egress to be running; run: just egress-up)
PASS: just build refuses an injection-shaped project name without executing it
PASS: agent-enter.sh refuses an injection-shaped project name (exit 2)
error: recipe `smoke-enter` failed on line 195 with exit code 1
```

Again no summary line (M6). The proxy had gone down again between my check and
the assertion. That is not flakiness in `agent-enter.sh`: the `egress-up`
recipe now carries a DNS-race detection loop that recreates `atelier-egress`
(see the "CORRECTED (Phase 2)" comment block added to the Justfile at 22:28),
and the executor working on it was cycling the container.

**Worth carrying forward as a follow-up:** the suite has no tolerance for a
proxy that restarts mid-run. Two of three runs were lost to it, and in the
second the failure surfaced as a `FAIL:` on the *self-refusal* assertion —
an assertion that has nothing to do with the proxy — which is actively
misleading. A proxy health check up front (alongside the existing
`agent-example:latest` precondition at `:73-77`), failing fast with "run
`just egress-up` first", would have turned both losses into one clear line.

---

# CRITICAL

## C1 — Self-refusal fails open when the repo is reachable by a second path

`scripts/agent-enter.sh:152-159` (and `:50`)

`check_self_refusal` compares two strings. `DIR` has been canonicalized with
`realpath -e` (`:141`), but `REPO_ROOT` has not (`:50` uses `cd … && pwd`).
More importantly, `realpath` resolves *symlinks*, not *bind mounts*, so two
paths that name the same directory can canonicalize to two different strings.

That is the situation on this host:

```
$ stat -c '%d:%i %n' /home/user/Documents/vibe-code/atelier-harness \
                     /var/home/user/Documents/vibe-code/atelier-harness
62:140854238 /home/user/Documents/vibe-code/atelier-harness
62:140854238 /var/home/user/Documents/vibe-code/atelier-harness

$ realpath -e /home/user/Documents/vibe-code/atelier-harness
/home/user/Documents/vibe-code/atelier-harness
$ realpath -e /var/home/user/Documents/vibe-code/atelier-harness
/var/home/user/Documents/vibe-code/atelier-harness
```

Same device, same inode, two stable canonical paths. Replaying the exact
comparison from `:155`:

```
REPO_ROOT=/var/home/user/Documents/vibe-code/atelier-harness
DIR=$(realpath -e /home/user/Documents/vibe-code/atelier-harness)
→ *** NOT REFUSED -- self-refusal bypassed ***
```

**Failure scenario.** The operator (or an agent writing a wrapper, or a
`cd /home/...` habit, or anything that resolves `$HOME` to the other root) runs
`agent-enter.sh --dir /home/user/Documents/vibe-code/atelier-harness`. Atelier
is bind-mounted at `/work` with no refusal and no `--allow-self`. An agent in
that container can then edit `containers/egress-proxy/allowlist.txt`, any
`Containerfile`, or the `Justfile`, and the change takes effect the next time
the owner builds. AUDIT §5 names this exact scenario as the reason the
consumption boundary "is a security boundary and not just a tidiness
preference". The one control enforcing it fails open.

I deliberately did **not** execute the bypass to completion (it would have
created a container with Atelier at `/work` and SELinux-relabelled the repo);
the comparison was replayed in isolation.

**Fix.** Compare by filesystem identity, walking up from `DIR`, and canonicalize
`REPO_ROOT` through `readlink -f` (see H5, same root cause):

```bash
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"

is_within_repo() {                       # by device+inode, not by string
  local probe="$1" root_id
  root_id="$(stat -c '%d:%i' "$REPO_ROOT")" || return 2
  while :; do
    [[ "$(stat -c '%d:%i' "$probe")" == "$root_id" ]] && return 0
    [[ "$probe" == "/" ]] && return 1
    probe="$(dirname "$probe")"
  done
}
```

Add a smoke assertion that enters via a second path to the same tree (a
`mount --bind` or a symlinked parent) and still gets exit 3. The current
suite's self-refusal test (`tests/smoke-enter.sh:81`) passes only because it
happens to use the identical string.

**Related, same root cause: a worktree or second clone is not refused.**
`check_self_refusal` asks "is this path under the directory the *script* lives
in", not "is this directory an Atelier checkout". A `git worktree` of Atelier,
or a second clone at another path, is therefore entered freely when invoked
through the main checkout's script — an inode check does not fix this one,
because it genuinely is a different directory. Reasoned, **not tested**: the
repo has no commits yet, so `git worktree add` cannot run here. The exposure is
lower than C1 (a build from the main checkout will not pick up edits made in a
worktree), but it is not nil — the worktree's changes reach the main checkout on
the next merge, and the operator's next build is still the trusted moment.
Suggested belt-and-braces alongside the inode check: also refuse when `DIR`
looks like an Atelier checkout by content, for example when
`${DIR}/scripts/source-sha.sh` and `${DIR}/containers/agent-base/Containerfile`
both exist, or when `git -C "$DIR" rev-parse --git-common-dir` resolves into
`REPO_ROOT`.

---

# HIGH

## H1 — A stale container silently keeps the old `/work`, ignoring `--dir`

`scripts/agent-enter.sh:314-324`

`ensure_container` branches on `podman container exists "$CONTAINER"` and, when
it exists, only starts it. `DIR` is never compared against the existing
container's `/work` source. `build_run_flags` is not even called.

Reproduced:

```
$ agent-enter.sh --project revprobe --dir /tmp/tmp.SiPFpqX6G5/revprobe --network none --no-tmux -- true
$ agent-enter.sh --project revprobe --dir /tmp/tmp.0iugl3ehFd/otherdir  --network none --no-tmux -- sh -c 'cat /work/marker.txt'
cat: /work/marker.txt: No such file or directory
$ podman inspect agent-revprobe --format '…/work source…'
/tmp/tmp.SiPFpqX6G5/revprobe          # still the FIRST directory
```

No warning is printed.

**Failure scenario.** Project name defaults to `basename "$DIR"`, so
`~/work/acme/frontend` and `~/personal/frontend` are both project `frontend`.
The operator opens the second, gets a shell that looks right, and the agent
edits and commits in the *first* repository. Composed with C1 and
`--allow-self`, it is also a second route past the self-refusal: once a
container for project `X` was created with Atelier at `/work`, every later
`--dir` for project `X` reuses that mount, and `check_self_refusal` — which only
ever inspects `DIR` — never sees it.

**Fix.** In the exists-branch, read the current bind source and compare:

```bash
existing_work="$("${PODMAN[@]}" inspect "$CONTAINER" \
  --format '{{range .Mounts}}{{if eq .Destination "/work"}}{{.Source}}{{end}}{{end}}')"
if [[ "$existing_work" != "$DIR" ]]; then
  echo "agent-enter: container ${CONTAINER} has ${existing_work} at /work, not ${DIR}; pass --rebuild to recreate it, or use a different --project" >&2
  exit 4
fi
```

Refuse rather than warn: a warning scrolls past an attach.

## H2 — The auth-volume probe runs a container with credentials on the open internet

`scripts/agent-enter.sh:239-249`

`ensure_auth_volume` mounts each credential volume into a throwaway container
just to run `ls -A`:

```bash
contents="$("${PODMAN[@]}" run --rm -v "${vol}:/probe:ro" "$IMAGE" bash -c 'ls -A /probe 2>/dev/null')"
```

That `podman run` carries **none** of the AUDIT §4.3 hardening and **no network
profile**: no `--network`, so it gets rootless Podman's default network with a
full route out; no `--cap-drop=ALL`, no `--security-opt=no-new-privileges`, no
`--userns=keep-id`, no `--read-only`, no `--pids-limit`.

Reproduced with the identical flags:

```
$ podman run --rm -v atelier-auth-claude:/probe:ro agent-base:latest bash -c \
    'getent hosts api.anthropic.com >/dev/null && echo DNS_OK || echo DNS_FAIL; \
     curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 https://api.anthropic.com/'
DNS_OK
404
```

DNS resolves and a real TLS connection completes. (I mounted the volume to
reproduce the network posture; I did not read or write any credential
content — the probe only exercised DNS and an HTTPS status code.)

**Failure scenario.** This runs on every first-run of a project, *before* the
network profile is honoured, including when the operator asked for
`--network none`. For the seconds it lives, a container holding the owner's
OAuth credentials has unfiltered egress that the entire AUDIT §4.2 design
exists to prevent. It also runs the *project overlay* image, whose Containerfile
is the thing an agent would target under C1/H1.

**Fix.** Do not start a container to stat a volume. Inspect the mountpoint
directly:

```bash
ensure_auth_volume() {
  local vol="$1" mp
  "${PODMAN[@]}" volume exists "$vol" 2>/dev/null || "${PODMAN[@]}" volume create "$vol" >/dev/null
  mp="$("${PODMAN[@]}" volume inspect "$vol" --format '{{.Mountpoint}}')"
  if [[ -z "$(ls -A "$mp" 2>/dev/null)" ]]; then
    echo "agent-enter: warning: auth volume ${vol} is empty -- 'just auth' has not populated it yet" >&2
  fi
}
```

If a container is unavoidable (rootless mountpoints can need `podman unshare`),
then at minimum add `--network=none --cap-drop=ALL
--security-opt=no-new-privileges --read-only` and use a neutral image rather
than the project overlay.

## H3 — `--network` is silently ignored on an existing container, and the proxied preflight is skipped

`scripts/agent-enter.sh:314-324`, `:230-236`

`check_network_preflight` and `build_run_flags` are both inside the
create-branch only. On the reuse path the requested profile has no effect and
is not checked.

Reproduced, with `atelier-egress` down and an existing `none`-network container:

```
$ agent-enter.sh --project revprobe --dir … --network proxied --no-tmux -- sh -c 'echo "HTTPS_PROXY=[${HTTPS_PROXY:-<unset>}]"'
HTTPS_PROXY=[<unset>]
EXIT=0
$ podman inspect agent-revprobe --format '{{json .NetworkSettings.Networks}}'
{"none":{…}}
```

Exit 0, no warning, no proxy.

**Failure scenario, two directions.** README "Entering a project" states the
proxied profile "never silently falls back to no egress control" — on this path
it does exactly that, and the `just egress-up` pointer never fires. The reverse
is worse: a container created under `proxied` and later entered with
`--network none` still has full proxied egress while the operator believes the
sandbox is offline. `--network` reads as a per-invocation switch and behaves as
a create-time-only one.

**Fix.** Same shape as H1 — compare the existing container's network against the
requested profile and refuse with a `--rebuild` pointer on mismatch. Run
`check_network_preflight` before *any* proxied attach, not only before create,
so a dead proxy is reported whichever branch is taken.

## H4 — A `.` in the project name permanently breaks the tmux layer

`scripts/agent-enter.sh:58` (`PROJECT_NAME_RE`), `:347-357`, `:300-302`

`PROJECT_NAME_RE='^[A-Za-z0-9._-]+$'` allows `.`, but tmux parses `.` in a
`-t` target as the window/pane separator. Reproduced end to end:

```
$ agent-enter.sh --dir /tmp/…/my.app --network none        # first call
…
$ tmux -L revdot list-sessions -F '#{session_name}'
agent-my.app                                               # session exists

$ tmux -L revdot has-session -t agent-my.app
can't find pane: project                                   # exit 1

$ agent-enter.sh --dir /tmp/…/my.app --network none        # second call
duplicate session: agent-my.app                            # exit 1
```

**Failure scenario.** `tmux_session_exists` always returns false, so
`enter_tmux` takes the create branch every time; the first call leaves a session
it can never find again, and every subsequent call dies with `duplicate
session`. The project is unenterable until the operator kills the session by
hand. `--rebuild` does not rescue it: its `kill-session` at `:300-302` is gated
on the same broken `tmux_session_exists`. Directory basenames with dots are
ordinary (`my.app`, `example.com`, `v2.0`, `foo.js`).

**Fix.** A trailing colon terminates the session name in tmux's target grammar.
Verified:

```
$ tmux has-session -t 'agent-my.app'      → can't find pane: app   (exit 1)
$ tmux has-session -t 'agent-my.app:'     → exit 0
```

Note the `=` exact-match prefix does **not** help — `=agent-my.app` still fails.
I checked all four subcommands the script uses against a live `agent-my.app`
session:

| Call | bare target | trailing colon |
|---|---|---|
| `has-session` | `can't find pane: app` (1) | exit 0 |
| `attach` | `can't find pane: app` (1) | `not a terminal` — target resolved |
| `switch-client` | — | `no current client` — target resolved |
| `kill-session` | — | exit 0, session killed |

Use `-t "${SESSION}:"` in `tmux_session_exists` (`:348`), `attach_or_switch`
(`:353`, `:355`) and `do_rebuild`'s `kill-session` (`:301`); `new-session -s`
takes a literal name and needs no change. Add a dotted-name case to the smoke
suite, and consider dropping `.` from `PROJECT_NAME_RE` as defence in depth.

## H6 — The tmux fast path skips the entire container layer, including the staleness check

`scripts/agent-enter.sh:365-376`

```bash
enter_tmux() {
  if tmux_session_exists; then
    attach_or_switch
    return 0          # <-- ensure_container is never reached
  fi
  ensure_container
```

The early return skips `ensure_container` and with it `check_staleness`,
`check_container_image_drift`, `check_network_preflight` and
`ensure_auth_volumes`.

**Spec violation.** AUDIT §3.1 requires that `agent-enter.sh` compare the label
"before attaching". On the session-exists path it never compares. That is the
*primary* workflow — a persistent container running `sleep infinity` exists
precisely so the operator reattaches to it day after day — so the operator who
uses Atelier as designed sees the staleness warning approximately never. The
smoke suite cannot catch this because its staleness assertions all run under
`--no-tmux`.

**The dead-pane race.** Reproduced with `remain-on-exit on`, a common tmux
setting (via `ATELIER_TMUX="tmux -L revdead2 -f /tmp/revconf"`):

```
1. agent-enter.sh --project deadpane2 --dir … --network none
   → container: EXISTS,  session agent-deadpane2 created
   → stderr: "warning: auth volume atelier-auth-codex is empty" (ensure_container ran)

2. podman rm -f agent-deadpane2
   → container: absent,  session agent-deadpane2 STILL PRESENT

3. agent-enter.sh --project deadpane2 --dir … --network none
   → stderr: "no containers/deadpane2/Containerfile found" then "no current client"
   → NO auth-volume warnings this time  ← proof ensure_container was bypassed
   → *** container: STILL ABSENT -- attached to a dead pane ***
```

The missing auth-volume warnings in step 3 are the direct evidence that the
container layer was skipped. The user attaches to a corpse with no error
explaining it, and no invocation of `agent-enter.sh` will ever repair it —
`--rebuild` is the only escape, and only because it kills the session first.

With tmux's default `remain-on-exit off` the session dies with its pane, so the
common case self-heals; I verified that too. But the staleness half of this
finding holds unconditionally, on every attach, regardless of tmux settings.

**Fix.** Call `ensure_container` before the session-exists branch, not after it:

```bash
enter_tmux() {
  ensure_container            # always: staleness, drift, network, auth, start
  if tmux_session_exists; then
    attach_or_switch
    return 0
  fi
  …
```

`ensure_container` is already idempotent, so this costs one `podman container
exists` plus the staleness hash on the attach path. Add a smoke case that
removes the container behind a live session and asserts it is recreated.

## H5 — `REPO_ROOT` is not canonicalized, so a symlinked entry point breaks two ways

`scripts/agent-enter.sh:50`

```bash
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

`BASH_SOURCE[0]` is the path as invoked. Symlinking the script into a `bin`
directory — the obvious way to use something named `agent-enter` — makes
`REPO_ROOT` the parent of that bin directory. Reproduced with
`/tmp/revbin/agent-enter -> …/scripts/agent-enter.sh`, giving `REPO_ROOT=/tmp`:

```
$ /tmp/revbin/agent-enter --dir /tmp/tmp.AUSKqwh01c/someproj --network none --no-tmux -- true
agent-enter: refusing to bind /tmp/tmp.AUSKqwh01c/someproj as /work: it is this
repository (Atelier itself) or a path inside it. …
EXIT=3

$ /tmp/revbin/agent-enter --dir /var/home/user/Documents --network none --no-tmux -- true
agent-enter: no containers/Documents/Containerfile found; using agent-base:latest
/tmp/revbin/agent-enter: line 204: ./scripts/source-sha.sh: No such file or directory
EXIT=127
```

So: unrelated directories are refused with a message asserting they are the
Atelier repository, and directories outside the bogus root crash with a bare
`No such file or directory` and exit 127 rather than a handled error.

**Fix.** `REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)"`,
plus a startup assertion that `${REPO_ROOT}/scripts/source-sha.sh` and
`${REPO_ROOT}/Justfile` exist, failing with an explicit exit code and a message
naming the resolved root.

---

# MEDIUM

## M1 — The smoke test SELinux-relabels the Atelier repository, and can leave a container holding it

`tests/smoke-enter.sh:92-97`

The `--allow-self` assertion really does start a container with `REPO_ROOT`
bind-mounted `:Z`. `:Z` relabels recursively with a private MCS category.
Observed after the run:

```
$ ls -ldZ . Justfile scripts
drwxr-xr-x. … system_u:object_r:container_file_t:s0:c56,c905 …
-rw-r--r--. … system_u:object_r:container_file_t:s0:c56,c905 … Justfile
drwxr-xr-x. … system_u:object_r:container_file_t:s0:c56,c905 … scripts
```

Running the test mutates the labels of the repository the test lives in. Any
other container or confined process with a different MCS category loses access
until `restorecon -R` is run. Separately, the container `agent-atelier-harness`
is removed at `:97` but is **not** in `cleanup()` (`:58-63`), so an interrupt
between `:92` and `:97` leaves a live container with Atelier at `/work` — the
precise state the design forbids.

**Fix.** Add `agent-atelier-harness` to the trap. Assert `--allow-self` without
starting a container (for example a `--dry-run` flag that stops after
`check_self_refusal`), or point the `--allow-self` case at a throwaway copy of
the repo so the real tree is never relabelled. If the relabel stays, say so in
the README next to `just smoke-enter` and give the `restorecon -R` recovery.

## M2 — Nothing guards `--dir` against `$HOME` or `/`

`scripts/agent-enter.sh:141-149`, `:262`

`--dir "$HOME"` is accepted: project becomes `basename $HOME`, and
`--volume "$HOME:/work:Z"` recursively relabels the entire home directory —
breaking the `dev` distrobox and `claude-desktop`, which mount it — while
mounting all of `$HOME` into an agent container. That is the "no `$HOME`
mounts" rule in AUDIT §4.1 defeated by a typo. Not reproduced: doing so would
have relabelled the operator's home directory.

**Fix.** Refuse `--dir` equal to `$HOME`, `/`, or any of `/etc /usr /var`, by
device+inode (the same helper as C1). Optionally warn above a file-count
threshold, since `:Z` cost scales with tree size.

## M9 — `:Z` on a project dir inside `$HOME` breaks other containers that mount `$HOME`

`scripts/agent-enter.sh:262`, AUDIT.md §4.3

Distinct from M2, which is about mounting `$HOME` itself. This is the ordinary
case: a project at `~/code/foo`. `:Z` relabels it with a **private** MCS
category, readable only by the container that owns the label. AUDIT §4.3
justifies choosing `:Z` over `:z` with "the PRP says only the project dir is
mounted, and nothing else on the host needs to read it while labelled."

That premise is false on this host. Two long-running containers mount `$HOME`
right now:

```
$ podman ps --format '{{.Names}}|{{.Status}}'
dev|Up 3 days
claude-desktop|Up 3 days
```

Any project under `$HOME` that `agent-enter.sh` touches is relabelled out from
under both of them. The effect is directly observable on this repository, which
the smoke test relabelled (M1):

```
$ ls -ldZ .
drwxr-xr-x. … system_u:object_r:container_file_t:s0:c56,c905 …
```

The owner's own `dev` distrobox — the shell `agent-enter.sh` is designed to be
invoked *from*, per AUDIT §4.4 — is one of the containers that loses access.

**Fix.** This challenges a spec decision, so it is the owner's call rather than
a code defect to silently patch. Options, in order of preference:

1. Keep `:Z` and document the consequence in the README next to "Entering a
   project", with the `restorecon -R -v <dir>` recovery. Cheapest, honest.
2. Use `:z` (shared label) for project directories specifically. It is weaker —
   any container can then read them — but it matches the actual topology, where
   several of the owner's containers legitimately share `$HOME`. AUDIT §4.3's
   claim that `:z` "is not used anywhere in this repo" would need revisiting.
3. Detect the conflict: warn when `DIR` is under `$HOME` and any other running
   container mounts `$HOME`.

Whichever is chosen, AUDIT §4.3's stated rationale should be corrected, since
it rests on a premise this host contradicts.

## M3 — Vacuous assertions in the smoke suite

- `tests/smoke-enter.sh:243` — `FRESH_OUT="$(enter …)" || true`, then the test
  passes when `looks stale` is *absent*. Any failure of `enter` (image gone,
  proxy down, podman error) produces output without that string and the
  assertion **passes**. This is the negative assertion AUDIT §5 warns about:
  "A negative assertion that passes on any failure is worth less than no
  assertion." Fix: assert `enter` exits 0 first, then grep.
- `tests/smoke-enter.sh:202` and `:255` — `enter … >/dev/null 2>&1` with the
  status unchecked before comparing container ids. If the second invocation
  crashes instantly, the id is trivially unchanged and "reuses the same
  container" / "--rebuild produces a new container id" still report on stale
  state.
- `tests/smoke-enter.sh:305-315` — the "second invocation attaches rather than
  creating a second session" check only counts sessions. It cannot distinguish
  *attached* from *failed before doing anything*, and in fact `attach_or_switch`
  does fail here: with `ATELIER_TMUX` pointing at a private socket while the
  runner may itself be inside tmux, `switch-client` reports `no current client`
  and `agent-enter.sh` exits 1. The assertion passes anyway. Fix: assert the
  session's pane command still names the podman exec, and assert the invocation
  did not create a second session *and* did not error for an unrelated reason.
  (Which error appears depends on whether the runner is itself inside tmux:
  with `TMUX` set, `attach_or_switch` takes the `switch-client` branch and
  reports `no current client`, which is what I observed in my own probe; with
  `TMUX` unset it takes `attach` and reports `not a terminal`. Either way the
  invocation exits 1 and the assertion still passes.)
- `tests/smoke-enter.sh:193` — `JQ_OUT=… || true` hides a failing `podman exec`
  behind a `jq --version` string check.

## M4 — The smoke test destroys real state named `agent-example`

`tests/smoke-enter.sh:41,54,60,228-240`

`TEST_PROJECT` is fixed at `example`, so `cleanup()` runs
`podman rm -f agent-example` unconditionally. If the operator has a live
`agent-example` session (the reference overlay is exactly what someone
experimenting would open), `just smoke-enter` destroys it along with its session
state — the thing AUDIT §3.1 says must never be auto-recreated.

Worse, `:229` rebuilds the **real** `agent-example:latest` tag with a
deliberately wrong `SOURCE_SHA` label. It is repaired at `:242` only on the
happy path; an abort in between leaves the operator's tagged image
permanently mislabelled, and the repair is not in the trap.

**Fix.** Build the deliberately-stale image under a scratch tag
(`agent-example-smoke:latest`) and drive `agent-enter.sh` at a scratch project
name, or restore `agent-example:latest` from the trap. Guard the whole run
behind a check that no pre-existing `agent-example` container is running, and
say so in the README.

## M5 — Project-name sanitizers have drifted between the Justfile and the script

`Justfile:142` rejects `.` and `..` explicitly on top of the regex.
`scripts/agent-enter.sh:58,131-138` uses the same regex but **omits** the
`.`/`..` rejection, and `^[A-Za-z0-9._-]+$` matches both.

Today the consequences are contained: `--project ..` resolves
`containers/../Containerfile`, which does not exist, so it falls back to
`agent-base`. But `expected_source_sha` would then hash `containers/..`, and
the container name `agent-..` is accepted by podman. The comment at
`Justfile:136-138` explains precisely why the `.`/`..` check is needed and the
script does not carry it.

**Fix.** Move the rule into one place. Either have `sanitize_project_name`
reject `.` and `..` with the same message, or better, have both read a single
`scripts/valid-project-name.sh` so the two cannot drift — the same argument the
repo already makes for `source-sha.sh`.

## M6 — An unguarded failure aborts the smoke test with no summary and no FAIL

`tests/smoke-enter.sh:133`, `:202`, `:255`

These are bare commands under `set -e`. When `enter` fails, the script dies
immediately: no `FAIL:` line, no `== summary ==`, and an exit code that is
podman's rather than the suite's. That is what happened in **two of my three
runs** — a handful of PASSes and then nothing. A harness reading the summary
line sees no result at all, and cannot tell a broken state machine from an
absent proxy.

**Fix.** Wrap each in a checked form that records a FAIL and continues (or
records a FAIL and then exits via the normal summary path), matching how
`:73-77` and `:134-140` already handle fatal preconditions. This is the single
highest-value fix in the suite: it is what stopped two of my three runs from
producing any reviewable result, and on a shared podman host it will keep
happening.

## M7 — Fixed `/tmp` paths for test output

`tests/smoke-enter.sh:81,88,92,95,230,238,242,250`

`/tmp/smoke-enter-self.out`, `-allow.out`, `-stale-build.out`, `-rebuild.out`
are hardcoded inline rather than declared with the other constants at
`:41-45`, are never removed by `cleanup()`, collide between concurrent runs, and
sit in a world-writable directory where a pre-planted symlink redirects the
write. Fix: `mktemp` inside `$WORKDIR`, which the trap already removes.

## M8 — State-machine branches with no coverage

By inspection of `tests/smoke-enter.sh` against `agent-enter.sh:326-330`:

- **`start_if_stopped`** — the "container exists but stopped → `podman start`"
  branch, called out explicitly in AUDIT §7 and the README, is never exercised.
- The proxied preflight failure path (`:230-236`) is never asserted, so the
  `just egress-up` pointer is untested. Ironically it is the only thing that
  fired in my run.
- `--dir` change and `--network` change on an existing container (H1, H3).
- A trailing command given **without** `--` (`parse_args:125`).
- `--allow-self` is tested for permission but the resulting mount is never
  asserted.

**Fix.** Add a stopped-container case (`podman stop`, then `enter`, then assert
`.State.Running` is true and the id is unchanged) and a preflight case that
stops `atelier-egress` and asserts exit 1 plus the pointer text.

---

# LOW

- **L1** `agent-enter.sh:373` builds the tmux command with `printf '%q '`,
  which emits bash-specific `$'…'` quoting; tmux runs the string under
  `/bin/sh`. Harmless for sanitized project names and ordinary paths, but it is
  a latent mismatch if `DIR` ever reaches that string.
- **L2** shellcheck 0.11.0 is clean of errors and warnings apart from one false
  positive. `shellcheck -x scripts/agent-enter.sh scripts/source-sha.sh
  tests/smoke-enter.sh` reports only: SC2054 at `agent-enter.sh:259` (false
  positive — the commas are inside `--userns=keep-id:uid=1000,gid=1000`),
  SC2329 at `smoke-enter.sh:58` (`cleanup` is invoked via `trap`), and four
  SC2015 infos on `A && pass || fail` lines (`:122`, `:133`, `:136`, `:187`) —
  benign here because `pass` always returns 0, but the pattern is worth
  replacing with `if`/`else` since a future `pass` that can fail would silently
  double-count.
- **L3** `cleanup()` runs `tmux kill-server` but leaves the socket file
  `/tmp/tmux-1000/atelier-test` behind. Cosmetic.
- **L4** `ensure_image_built:177` and `do_rebuild:304-307` invoke `just` without
  checking it is installed; a missing `just` surfaces as a bare
  `command not found`.
- **L5** `check_staleness:212` treats a missing label and a mismatched label
  identically. Podman renders a missing key as `<no value>`, which will warn
  "looks stale" — defensible, but the message will name a nonsense
  `<no value...` prefix rather than saying the label is absent.

---

# What I verified as correct

**The staleness inputs genuinely cannot drift (AUDIT §3.1).** This was the item
I most expected to find broken; it holds.

- `Justfile:163-164` and `agent-enter.sh:194-207` both `cd` to the repo root
  first and pass the **same relative path strings** (`containers/<project>`,
  `containers/agent-base`). The comment at `agent-enter.sh:185-193` correctly
  identifies why absolute paths would break it: `source-sha.sh` hashes the path
  *text* into the manifest.
- Both enumerate agent-base at call time with the identical
  `find containers/agent-base -type f -print0` (Justfile via `mapfile -d '' -t`,
  script via a `while IFS= read -r -d ''` loop) rather than a hardcoded file
  pair, so agent-base changing shape cannot desynchronize them.
- `source-sha.sh:60` sorts the union with `LC_ALL=C sort` before hashing, so
  neither `find` traversal order nor the order extras were passed matters. The
  two call sites can pass the same set in different orders and still agree.
- Empirically identical:
  ```
  $ ./scripts/source-sha.sh containers/example $(find containers/agent-base -type f | sort)
  88580b5bd1f1bba589e915a1bfced079635376655b2b4ed3b8db42a476f6032f
  $ podman image inspect agent-example:latest --format '{{index .Labels "org.atelier.source-sha"}}'
  88580b5bd1f1bba589e915a1bfced079635376655b2b4ed3b8db42a476f6032f
  ```
- `source-sha.sh` fails closed on a missing extra file (`:44-50`), a
  non-directory (`:34-37`) and an empty input set (`:52-55`), each with a
  distinct message and an explicit exit code.

**The run flags match AUDIT §4.3 exactly, with no extra mounts.** Verified on a
container created by the script (`--network none`, scratch dir):

```
.Mounts:   volume /home/agent/.claude, volume /home/agent/.codex,
           volume /home/agent/.config/gh, bind /work        (exactly 4)
HostConfig.Tmpfs: /tmp, /home/agent/.cache, /home/agent/.npm,
           /home/agent/.local/share, /home/agent/.config    (5 entries)
HostConfig.ReadonlyRootfs: true
```

The comment's central claim is true: `--tmpfs` entries appear only under
`HostConfig.Tmpfs`, never in `.Mounts`, so the read-only experiment does not
weaken the "exactly `/work` plus the three auth volumes" assertion at
`tests/smoke-enter.sh:138-144`. The `gh` volume mounted *under* the `.config`
tmpfs does survive — both appear, correctly ordered. `--cap-drop=ALL`,
`--security-opt=no-new-privileges`, `--init`, `--pids-limit=2048` and
`--userns=keep-id:uid=1000,gid=1000` are all present at `:259-278` verbatim per
§4.3, and the smoke suite checks the *effective* result (`CapBnd` all zeros,
`NoNewPrivs: 1`, container uid 1000) rather than just the flag — the right
choice.

One gap worth noting rather than filing: nothing asserts `:Z`. `podman inspect`
does not expose the SELinux relabel in `.Mounts .Mode` or `.Options` (observed:
`mode=[] opts=[nosuid nodev rbind]`), so the smoke test cannot see it. A
`ls -Z` of the host directory after a run would.

**Justfile `{{project}}` handling is sound against injection and traversal.**
`Justfile:141` uses `quote(project)` exactly once to capture into a bash
variable and never interpolates the raw parameter again; the regex at `:142`
additionally rejects `.` and `..`. Probed live:

```
$ just build 'z", echo INJECTED >&2, #'
build: invalid project name 'z", echo INJECTED >&2, #' (must match ^[A-Za-z0-9._-]+$, and not be '.' or '..')
$ just build '../etc'
build: invalid project name '../etc' …
$ just build '..'
build: invalid project name '..' …
```

No injection, no traversal; the comment at `:126-138` describes the mechanism
accurately. (The script-side gap is M5, not a Justfile defect.)

**The new injection assertions (`tests/smoke-enter.sh:99-130`) are correctly
built** — this is the best-reasoned assertion in the suite. It would have been
easy to grep the output for `INJECTED` and get a false positive, because the
rejection message legitimately echoes the payload back as quoted data. Using
`grep -qx 'INJECTED'` to demand the string *alone on its own line* genuinely
distinguishes "the payload was rejected and echoed" from "the payload
executed", and the comment at `:108-114` explains exactly that. Both layers are
covered (the Justfile recipe and `sanitize_project_name`), each asserts a
specific exit code rather than mere failure, and `JUST_INJECT_EXIT` is
`unset` afterwards so it cannot leak into the next check. Both passed in my
second run.

**`build-egress` allow-list union is correct.** `Justfile:95-108` stages into a
`mktemp -d` with a `trap 'rm -rf "$STAGE"' EXIT`, passes it as a named build
context rather than copying into the tracked tree, skips
`containers/egress-proxy/allowlist.txt` when globbing so the base list is not
duplicated, guards the glob with `[[ -e "$f" ]] || continue` against a
no-match literal, and feeds exactly the per-project lists it staged into
`source-sha.sh` as extras — so a change to any project's additions does change
the proxy image's fingerprint. The README documents the union's security
consequence (any project's host becomes reachable from every container)
plainly rather than burying it.

**Coding-style rules.** All 27 functions in `agent-enter.sh` are well under 50
lines (longest: `build_run_flags`, 28). Files are 398 / 62 / 288 lines, under
the 800 cap. `agent-enter.sh` contains **zero** `|| true` — the only match is
the word inside the header comment at `:45`, so the file's own claim is
accurate. Constants are hoisted to `:49-58` and every one is env-overridable.
Exit codes are explicit and distinct: 2 for usage, 1 for environment, 3 for
self-refusal, and the smoke suite asserts the 3. Error messages go to stderr
throughout and name the remedy (`just egress-up`, `just build-base`,
`--rebuild`, `--allow-self`). `smoke-enter.sh` has 17 `|| true`, of which most
are legitimate cleanup idempotence; the three that hide real failures are filed
as M3.

**`containers/example/`** matches the README convention exactly: `FROM
agent-base:latest`, `USER root` only for the install layer, the same
`--setopt=install_weak_deps=False` flags, `ARG SOURCE_SHA`/`BUILD_CREATED`
consumed into labels, no `ENTRYPOINT`, and `USER agent` last. The
`allowlist.txt` comment states the union semantics and the
`^[A-Za-z0-9.-]+$` validation entrypoint.sh applies.

**"Container exists under a different image" is handled, and warn-only is the
right call.** `check_container_image_drift` (`:219-227`) compares the
container's `.Image` id against the current image id and warns with a
`--rebuild` pointer. Warning rather than refusing is *correct* here and
deliberately different from what I recommend for H1 and H3: AUDIT §3.1 is
explicit that the entry script "**never** auto-recreates a persistent
container", and an image that moved on is not a lie about what the operator
asked for — unlike a `/work` or a network profile that silently contradicts the
flags on the command line. Two caveats, neither a defect in the function
itself: it is unreachable on the tmux attach path (H6), and no smoke assertion
exercises it, so its message has never been seen fire.

**`--rebuild` ordering is safe.** `do_rebuild:298-311` kills the session, then
rebuilds, then removes the container — so a failed build aborts under `set -e`
*before* the container is destroyed, leaving the old container and its session
state intact. That is the correct order for AUDIT §3.1's "never auto-recreate a
persistent container".

---

# Recommended disposition

**BLOCK** on C1. It is the control AUDIT §5 designates as the consumption
boundary, and it fails open on this host today.

Fix C1 and H5 together (one `readlink -f` plus an inode comparison), then H1 and
H3 together (one "does the existing container match what was asked for?" gate in
`ensure_container`), then H2 (drop the probe container), H4 (trailing colon on
tmux targets) and H6 (move one line in `enter_tmux`). H1/H3 and H2 are each a
few lines; H4 is a one-character change in four places plus a test; H6 is a
two-line reordering.

Note that H6 and M8 compound: the tmux attach path is both the least-tested and
the most-used, and it is the path on which AUDIT §3.1's staleness guarantee
silently does not hold. The suite runs almost everything under `--no-tmux`,
which is precisely the path an operator never takes.

M9 is the one item that is not a code defect — it challenges AUDIT §4.3's
stated premise for choosing `:Z`, and needs an owner decision rather than a
patch.

Before re-review, the smoke suite needs M3, M4 and M6 addressed, otherwise it
cannot distinguish a fixed state machine from a broken one — and it needs a
clean full run, which is currently blocked on `atelier-egress` being absent.
