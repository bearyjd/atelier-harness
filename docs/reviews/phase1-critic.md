# Phase 1 Adversarial Review — Atelier

**Reviewer:** stand-in for Codex (quota-blocked).
**Repo:** `/var/home/user/Documents/vibe-code/atelier-harness`
**Date:** 2026-09-21
**Lanes:** spec conformance, Justfile, smoke test, README, maintainability, AUDIT corrections.
Egress/supply-chain/privilege attack surface deferred to the concurrent security reviewer.

**Severity counts:** 2 CRITICAL · 4 HIGH · 11 MEDIUM · 7 LOW · 16 verified-correct · 10 AUDIT corrections.

---

## Headline

`just smoke` reports **18 passed, 0 failed, 0 skipped**. That number is not trustworthy.

Two of the eighteen assertions cannot fail under any circumstances, and the single most
important recipe in the repo, `just auth`, is broken in a way nothing tests. The security
*properties* mostly do hold — I verified several independently, and some of the build's
choices are better than its own comments claim. The *evidence* the build offers for those
properties does not hold.

---

## CRITICAL

### C1. `just auth` writes credentials the agent user cannot read

`Justfile:120-121`

```
tar -cf - -C "$(dirname "$src")" --owner=1000 --group=1000 "$(basename "$src")" \
    | {{podman}} volume import "$volume" -
```

`--owner=1000` is the bug. In rootless Podman the import runs in the default user
namespace, where container uid 1000 maps to host subuid `524288 + 999 = 525287`. At run
time `--userns=keep-id:uid=1000,gid=1000` builds a *different* map in which host 525287
lands on container uid **999**. The file is mode 0600 owned by 999; the agent user is 1000.

Verified with a dummy file, never the owner's real credentials:

| tar flag | uid inside container | agent read |
|---|---|---|
| `--owner=1000` (as shipped) | 999 | Permission denied |
| `--owner=0` | 1000 | succeeds |

Host-side listing confirmed the file at `525287:525287`; the in-container `stat` reported
`uid=999 gid=999 mode=600`.

**Why it matters.** This recipe is the *entire* named carve-out to the "no `$HOME` mounts"
rule in AUDIT §4.1. `claude`, `codex` and `gh` will all fail to authenticate, and the
failure surfaces as an opaque auth error deep inside a container. The predictable reaction
is to bind-mount `$HOME` instead, which is precisely the security regression §4.1 exists to
prevent. Nothing in `tests/smoke.sh` touches the auth volumes, so the suite is green while
the feature is dead.

**Fix.** Change to `--owner=0 --group=0` (container uid 0 maps to host uid 1000 maps to
container 1000 under `keep-id`) — verified working. Then add a smoke assertion that mounts
each auth volume and reads a file as uid 1000.

### C2. The "immutable" Meute pin tag is currently `gnogit` and is mutable

`Justfile:23`

```
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
```

The repo has **zero commits** (`fatal: your current branch 'master' does not have any
commits yet`). `podman images` right now shows `localhost/agent-base   gnogit`, built
alongside `latest` and `20260921` off the same image ID `f3ba61b05921`.

**Why it matters.** AUDIT §3.2 makes `g<sha>` the one immutable tag and builds Meute's whole
review gate on it: *"a rebuild that silently reused a tag fails loudly instead of running on
an image nobody reviewed."* A tag that is always `gnogit` is overwritten by every build, so
it is mutable while looking immutable. There is also no dirty-tree guard: once commits
exist, `g<sha>` will happily be stamped onto an image built from uncommitted edits, breaking
the same guarantee more subtly.

**Fix.** Fail the build rather than invent a tag. Resolve `HEAD`, and if that fails — or if
`git status --porcelain` is non-empty — skip the `g<sha>` tag entirely and print why. A
release build should refuse outright on a dirty tree.

---

## HIGH

### H1. The `$HOME is not a separate mount point` assertion can never fail

`tests/smoke.sh:90`

```
HOME_MOUNT=$(awk -v h="$HOME" "\$2==h{print \$2}" /proc/self/mountinfo | head -1)
```

In `/proc/self/mountinfo`, field 2 is the **parent mount ID** (an integer). The mount point
is field **5**. The comparison `$2 == "/home/agent"` is never true.

Proven by mounting a volume directly at `/home/agent` and re-running both versions:

```
HOME_MOUNT(smoke $2 logic)=[]             <- check still PASSES
HOME_MOUNT(correct $5 logic)=[/home/agent]
```

**Why it matters.** This is the assertion enforcing the headline rule of the whole design,
"no `$HOME` mounts", which README lines 54-56 and AUDIT §4.1 both advertise. It would not
catch the exact regression it exists to catch. The adjacent dotfile check at
`tests/smoke.sh:91-93` is vacuous by construction too, since nothing is mounted over
`/home/agent` in the tested configuration.

**Fix.** Use `$5`, or read `/proc/self/mounts` where field 2 *is* the mount point. Then make
the check meaningful by asserting it in a run that deliberately mounts the auth volumes, so
it verifies "only the three expected volumes are mounted under `$HOME`" rather than
"nothing is".

### H2. The allow-list anchoring check proves nothing

`tests/smoke.sh:231`, using `github.com.attacker.invalid`.

`.invalid` is an IANA-reserved TLD that never resolves; confirmed, `getent` exits 2.
Measured through the proxy, every failure mode is indistinguishable:

| host | http_code | curl exit |
|---|---|---|
| `api.github.com` (allow-listed) | 200 | 0 |
| `example.com` (filtered, resolvable) | 000 | 56 |
| `github.com.attacker.invalid` (filtered + unresolvable) | 000 | 56 |
| `totally-not-related.invalid` (unresolvable) | 000 | 56 |
| `gist.github.com` (resolvable, real substring) | 000 | 56 |

The test passes identically whether the filter is anchored or not, because an unanchored
filter would let the request through to a DNS lookup that fails anyway. It is testing DNS,
not the regex.

**Good news, separately established:** anchoring genuinely works. `gist.github.com` resolves
publicly and contains the allow-listed `github.com` as a substring, and the proxy refused it.

**Fix.** Use `gist.github.com` as the substring probe, and assert on tinyproxy's own refusal
rather than on curl's generic failure, by grepping `podman logs atelier-egress` for the
filtered-domain message. That distinguishes "refused by policy" from "could not connect".

### H3. `egress-up` rebuilds the image, then keeps running the old container

`Justfile:60, 69-72`

The recipe depends on `build-egress`, so every invocation rebuilds. It then branches on
`container exists` and, if so, prints `"Container atelier-egress already exists; leaving it
running"` and does nothing else.

**Why it matters.** The allow-list is compiled into tinyproxy's filter by `entrypoint.sh`
**at container start**. Edit `allowlist.txt`, run `just egress-up`, and you get a freshly
built image that is not running, plus a reassuring success message. The proxy silently
enforces the old policy. The recipe is idempotent but not convergent, and the message
actively misleads.

I checked the currently running container and it is *not* stale: its image ID
(`e180c1d6b7f8…`) and `org.atelier.source-sha` (`4ecc91bd7f79…`) both match
`atelier-egress:latest` and the sha the Justfile computes right now. **The defect is latent,
not active.**

**Fix.** Compare the running container's `org.atelier.source-sha` label against the freshly
computed one and recreate on mismatch, or add an explicit `egress-restart`. At minimum,
print the running container's source-sha so drift is visible.

### H4. The `resolv.conf` bind mount is unnecessary and its stated justification is wrong

`containers/egress-proxy/resolv.conf:6-14` claims Podman "writes the internal network's
aardvark-dns server into /etc/resolv.conf **ahead of any `--dns` flags**."

That is false. Measured:

```
control (no mount, no --dns):   nameserver 10.89.13.1              -> RESOLVE FAILED
--dns=1.1.1.1 (no mount):       nameserver 1.1.1.1
                                nameserver 10.89.13.1              -> RESOLVED 140.82.114.5
```

`--dns` is placed **first**, and resolution works. The underlying problem the builder found
is real; the remedy chosen for it is not the simplest one that works.

**Why it matters.** The bind mount costs four things the flag does not:

- It uses `:z` (shared relabel) at `Justfile:84`, where AUDIT §4.3 mandates `:Z` and README
  line 55 advertises "private SELinux relabel". Every container on the host can read a
  `container_file_t`-shared file.
- It SELinux-relabels a file **inside the git working tree**.
- It hardcodes an absolute repo path into a `--restart=always` container. Move or rename the
  repo and the proxy fails to start on next boot.
- It *replaces* the aardvark nameserver, so `atelier-egress` permanently loses the ability to
  resolve any container name on `atelier-internal`. The `--dns` form keeps it as a fallback.

**Fix.** Replace the volume mount with `--dns=1.1.1.1 --dns=9.9.9.9` and delete
`containers/egress-proxy/resolv.conf`. Lift the resolver addresses to Justfile variables
rather than burying them in a file; note they bypass the host resolver, and the `search` line
shows a Tailscale MagicDNS domain in use on this host, so that bypass is a real behavioural
choice worth stating.

---

## MEDIUM

### M1. `smoke.sh` asserts version pins for two tools that are not pinned

`tests/smoke.sh:34-35` hardcodes `GH_VERSION="2.97.0"` and `GIT_VERSION="2.55.0"`. Neither
appears in any Containerfile. Both come from unpinned `dnf install gh git-core` at
`containers/agent-base/Containerfile:37-38`, so they float with the base digest.

The test therefore asserts a pin that does not exist. It records whatever happened to be
installed, and will fail on the next base-digest bump for no security reason, training
whoever sees it to edit the expected value rather than investigate. AUDIT §6 lists pins "as
`ARG`s so Renovate can bump them" and does not mention gh or git.

**Fix.** Either pin both via `dnf install gh-<ver> git-core-<ver>` with ARGs, matching the
stated policy, or drop the exact-version assertion to a presence-and-parses check and say in
AUDIT §6 that gh and git ride the base image.

### M2. Nothing asserts that `atelier-internal` has no route out

This is the load-bearing claim of AUDIT §4.2, and `tests/smoke.sh` never checks it. I
verified it independently and it holds: on `atelier-internal` with no proxy environment, a
raw-IP curl to `1.1.1.1` fails with exit 7, `api.github.com` fails with exit 6, and there are
zero default routes.

The gap matters because if the network is ever recreated without `--internal`, every existing
proxy assertion still passes while egress is wide open. The suite would stay green through a
total loss of containment.

**Fix.** Add a no-proxy curl to a raw IP on `atelier-internal` and assert failure.

### M3. `pi-flow` is installed but never verified, and exposes no command

`@kky42/pi-flow@3.1.3` is present in `npm ls -g`. It has **no `bin` field**, so there is no
`pi-flow` executable; `/home/agent/.local/bin` contains only `claude`, `codex`, `pi`.
`tests/smoke.sh` mentions pi-flow zero times (`grep -c` returns 0).

AUDIT §4.5 explicitly tasks Phase 1 with confirming it installs cleanly under
`--ignore-scripts`. It does, but the build records that nowhere checkable. README line 4 and
AUDIT §6 list it alongside the three CLIs in a way that implies it is one.

**Fix.** Assert the package resolves (`npm ls -g @kky42/pi-flow`) and note in README that it
is a library consumed by `pi`, not a command.

### M4. `build-egress` emits one tag where §3.2 specifies three

`Justfile:46` produces only `atelier-egress:latest`; `build-base` correctly produces all
three. Defensible, since Meute pins agent images and not the proxy, but it is an undocumented
divergence from a spec section written in absolute terms. See AUDIT correction A3.

### M5. The egress `SOURCE_SHA` omits a runtime input and is ambiguously concatenated

`Justfile:40` hashes `Containerfile + tinyproxy.conf + allowlist.txt + entrypoint.sh`. Two
problems. `resolv.conf` is excluded although it is part of the proxy's runtime contract, so
editing it leaves the staleness label unchanged. And `cat a b c | sha256sum` is undelimited,
so moving a line from one file to another produces an identical hash.

**Fix.** Hash a manifest of `sha256sum <file>` lines rather than the concatenated bytes, and
include every file the proxy depends on at run time.

### M6. Errors swallowed across three recipes

- `Justfile:71` — `podman start ... >/dev/null 2>&1 || true`. A proxy that fails to start is
  reported as success. Combined with `--restart=always` and tinyproxy's fail-closed exit
  (see verified item 4), a crash-looping proxy looks healthy.
- `Justfile:95-97` — `rm -f ... || true` and `network rm ... || true`, then an unconditional
  `echo "egress proxy stopped and removed"`. A network still in use by another container
  fails to remove and the recipe claims otherwise.
- `Justfile:116-118` — a missing credential file is skipped with `return 0`, so `just auth`
  exits 0 having imported nothing.

These conflate "not found, fine" with "failed, not fine", which the repo's coding-style rule
forbids.

**Fix.** Guard with `container exists` / `network exists` tests and let real failures
surface; have `auth` exit non-zero, or at least print a loud summary, if it imported nothing.

### M7. `FILTER_FILE` is an override that can only break the container

`containers/egress-proxy/entrypoint.sh:14` honours `${FILTER_FILE}`, but
`containers/egress-proxy/tinyproxy.conf:35` hardcodes `Filter "/tmp/tinyproxy/filter"`.
Setting the variable writes the allow-list somewhere tinyproxy never reads.

I tested this expecting a fail-open. It fails **closed**: tinyproxy logs
`filter file: No such file or directory` and the container exits 65. That is the right
behaviour and I credit it. But the knob has no valid use and its only reachable effect is to
brick the proxy.

**Fix.** Delete the `FILTER_FILE` indirection and use the literal path, or generate the
`Filter` line in the entrypoint from the same variable.

### M8. `entrypoint.sh` parses the allow-list with `xargs` and escapes only `.`

`containers/egress-proxy/entrypoint.sh:34` uses `line="$(echo "$line" | xargs)"` to trim
whitespace. `xargs` interprets quotes and backslashes, so an entry containing an unmatched
quote aborts the script under `set -e` and the container never starts. It also forks twice
per line.

Line 36 escapes only `.` via `sed -E 's/[.]/\\./g'`. Other ERE metacharacters pass through
into an anchored regex. A natural-looking overlay entry such as `*.github.com` becomes
`^*\.github\.com$`. The repo's own coding-style rule requires schema-based validation at
system boundaries, and an allow-list file is exactly such a boundary.

**Fix.** Trim with `${line#"${line%%[![:space:]]*}"}`-style parameter expansion, and validate
each entry against `^[A-Za-z0-9._-]+$`, failing loudly on anything else. Attack depth here
belongs to the security reviewer; this flags the mechanism choice only.

### M9. A populated auth volume silently shadows image content

`containers/agent-base/Containerfile:80` sets `CLAUDE_CONFIG_DIR=/home/agent/.claude`, and
the claude installer may write there during build. Podman copies image content into a volume
only when the volume is **empty**. Once `just auth` populates `atelier-auth-claude`, anything
the image placed in that directory is hidden with no warning.

**Fix.** Add a comment in the Containerfile and a line in README so this is a decision rather
than a surprise.

### M10. `just --list` output is unusable

```
auth         # needing a helper container).
build-base   # can detect drift between a running container and its current definition.
egress-up    # default `podman` bridge (AUDIT.md §4.2). Idempotent.
```

`just` takes only the final comment line before a recipe as its description. The long
explanatory blocks are excellent as comments and produce nonsense as help text.

**Fix.** Put a one-line summary immediately above each recipe and move the rationale above
that, separated by a blank line.

### M11. `.gitignore` does not exclude `.omc/`

`.gitignore` ignores `/scratch/` and `/tmp/`, neither of which exists, while `git status`
shows `.omc/` untracked. That directory currently holds session state, replay logs and a
state-mutation lock database. With zero commits so far, the first `git add -A` commits all
of it.

**Fix.** Add `.omc/`.

---

## LOW

### L1. The sudo-removal comment is factually wrong for this image

`containers/agent-base/Containerfile:55-57` claims the removal "cascades out sudo's own
dependencies (pam, authselect, libpwquality, cracklib, ...) ... verified empirically."

In the built image all four are **still installed** (`rpm -q` confirms `pam-1.7.2-2.fc44`,
`authselect-1.7.1-1.fc44`, `libpwquality-1.4.5-15.fc44`, `cracklib-2.10.3-1.fc44`); only
`sudo` was removed. The cascade happens on a *bare* base image, where I confirmed nine
packages come out, but the earlier `dnf install` layer makes pam a dependency of the
installed toolchain, so it stays.

The `--setopt=protected_packages=` flag is genuinely required — plain `dnf remove sudo` fails
with `Problem: The operation would result in removing the following protected packages: sudo`,
confirmed against the bare base — but it clears protection for *every* package to achieve a
one-package removal justified by a false premise.

Eleven setuid-root binaries remain, including `/usr/bin/su`, `/usr/bin/passwd`,
`/usr/bin/mount`, `/usr/bin/newgrp`, `/usr/bin/gpasswd`, `/usr/bin/chsh`,
`/usr/bin/unix_chkpwd`. Under `no-new-privileges` plus `--cap-drop=ALL` these are inert at
run time, so this is an accuracy and maintainability defect, **not an exploitable hole**.
Privilege-surface analysis belongs to the security reviewer.

**Fix.** Correct the comment to say what actually happens, and add a build-time assertion
(`! command -v sudo`) so the claim is enforced rather than narrated.

### L2. Dead code

`tests/smoke.sh:45-54` defines `check()`, never called.

### L3. `--network=none` is tested by DNS resolution only

`tests/smoke.sh:191-196` runs `getent`, where AUDIT §5 specifies `curl https://example.com`
fails. The property holds more strongly than the test shows: I confirmed a raw-IP curl to
`1.1.1.1` fails with exit 7 and zero routes exist. Worth testing the raw IP, since DNS
failure alone does not prove absence of a route.

### L4. `entrypoint.sh` discards `"$@"`

`containers/egress-proxy/entrypoint.sh:45` always execs tinyproxy, so
`podman run atelier-egress bash -c ...` silently starts the proxy instead. This cost me a
debugging cycle and will cost the next person one.

**Fix.** `if [ $# -gt 0 ]; then exec "$@"; fi` before the final exec.

### L5. Sudo removal in a second layer reclaims no space

`containers/agent-base/Containerfile:58` runs in its own layer, so sudo's bytes remain in the
image at 2.05 GB. Merging it into the preceding `RUN` would actually remove them.

### L6. `--restart=always` in rootless Podman does not survive reboot

Not without `podman-restart.service` enabled or a generated user unit. Worth a README note
given the proxy is described as long-lived.

### L7. Proxy `Allow` directives admit all RFC1918 clients

`containers/egress-proxy/tinyproxy.conf:15-17`, while the proxy also sits on the default
`podman` network. Flagged for the security reviewer's open-relay lane, not analysed here.

---

## Verified correct

Each checked rather than taken on trust.

1. **Security posture under the §4.3 flag set.** uid 1000 as user `agent`,
   `CapBnd=0000000000000000`, `NoNewPrivs=1`. Independently reproduced outside the smoke test.
2. **`sudo` is genuinely absent.** `rpm -q sudo` reports not installed; nothing on PATH.
3. **The allow-list filter is genuinely anchored.** `gist.github.com` resolves publicly,
   contains the allow-listed `github.com` as a substring, and the proxy refused it. This is
   the property H2's test failed to demonstrate, and it holds.
4. **The proxy fails closed.** Pointed at a nonexistent filter file, tinyproxy logs
   `filter file: No such file or directory` and exits 65 rather than serving unfiltered.
   Correct and important.
5. **`atelier-internal` has no route out.** No default route, raw-IP curl exit 7, hostname
   curl exit 6.
6. **`--network=none` blocks raw-IP egress**, not merely DNS. curl exit 7, zero routes.
7. **The allow-listed path works end to end.** `curl https://api.github.com` through the
   proxy returns HTTP 200 from a container with no direct route.
8. **CLI pins are real for the three that are pinned.** claude 2.1.278, codex 0.155.1,
   pi 0.73.1, all matching the `ARG`s.
9. **`pi-flow` installs cleanly under `--ignore-scripts`**, satisfying AUDIT §4.5.
   `@kky42/pi-flow@3.1.3` present in `npm ls -g`.
10. **All three required labels are present** on both images, with plausible values
    (`org.atelier.source-sha`, `org.opencontainers.image.source`, `.created`).
11. **`SOURCE_SHA` for `agent-base` hashes the right input** and matches the label on the
    built image.
12. **The `podman` wrapper works.** `path_exists("/run/.containerenv")` correctly resolves to
    `distrobox-host-exec podman` in every dry-run; `tests/smoke.sh:15-24` implements the §4.4
    pattern including the `ATELIER_PODMAN` override.
13. **`ARG` placement after `FROM`** is correct, and the comment explaining why is accurate.
14. **The running proxy is not stale.** Container image ID, container label and freshly
    computed sha all agree. H3 is a latent defect, not an active one.
15. **All seven recipes dry-run without error**, and `build-base` emits exactly the three tag
    names §3.2 specifies, modulo the `gnogit` value in C2.
16. **The repo is unmodified by this review.** `git status` unchanged; all probe containers
    and volumes removed; `atelier-egress` left running for the security reviewer.

---

## AUDIT.md corrections (lane 6)

Listed, not applied, per instructions.

- **A1 · §4.1** — record the rootless volume-ownership constraint. Credentials must be
  imported as uid 0 in the tar stream so they land on host uid 1000 and appear as container
  uid 1000 under `keep-id`. This is a genuine host fact of the same character as the §2
  table, discovered only by building.
- **A2 · §4.2** — record that a container joined to both an `--internal` network and the
  default bridge cannot resolve public hostnames from the injected aardvark nameserver, and
  that `--dns` is the remedy and *is* honoured ahead of the injected server. Contradicts what
  `containers/egress-proxy/resolv.conf` currently asserts.
- **A3 · §3.2** — the tag triple is specified with no rule for a repo without commits or with
  a dirty tree. State that `g<sha>` is emitted only for a clean, committed tree and is
  otherwise omitted. Also scope the triple explicitly to agent images, so
  `atelier-egress:latest` alone is conformant rather than a silent divergence (M4).
- **A4 · §4.3** — says `:Z` throughout; the egress proxy uses `:z`. State which applies
  where, or drop the mount entirely per H4.
- **A5 · §4.3** — the `--read-only --tmpfs` directive says "verify rather than assume". No
  verification happened in Phase 1. Either carry it to Phase 2 explicitly or mark it deferred.
- **A6 · §5** — the smoke-test contract says `curl https://example.com` fails under the
  `none` profile; the build asserts DNS resolution instead. Align the spec or the test.
- **A7 · §5** — the contract should additionally require asserting that `atelier-internal`
  has no route out (M2) and that the auth volumes are readable by uid 1000 (C1).
- **A8 · §6** — states "Pins, as `ARG`s" but omits `gh` and `git`, which the smoke test
  nonetheless pins by hand. Say explicitly that those two ride the base digest, or require
  pinning.
- **A9 · §6** — does not mention `CLAUDE_CONFIG_DIR`, which the build adds. Reasonable
  addition, currently undocumented.
- **A10 · §8 item 5** — the repo-name question is still marked open while the image labels
  already bake `github.com/bearyjd/atelier-harness`. Record the decision. Related: §2 is
  worth extending to note that `@kky42/pi-flow` ships no executable, so it cannot be
  smoke-tested the way the other CLIs are.
