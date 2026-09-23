# Atelier — Phase 0 Audit

**Date:** 2026-09-20 (Phase 0); corrected 2026-09-22 after Phase 1 review (Section 9)
**Input:** `docs/prp/atelier-prp.md`
**Method:** Read the PRP, then inspected the host this will run on (Tower),
the sibling repos it must stay compatible with (`bazzite-tower`, `meute`),
and the upstream packages that will be pinned. Everything below is
verified on this machine unless marked *unverified*.

---

## 1. Verdict

The design holds. Two-consumer split, rootless Podman only, per-project
overlay images, tmux → container → shell entry: all sound and all
buildable on this host as-is.

Six things the PRP doesn't cover would have surfaced as blockers or
security regressions during Phase 1, so they are settled or escalated
here (Section 4). The three open questions are answered in Section 3.
The reference `agent-enter.sh` is **not on disk anywhere**; Phase 2 cannot
start until the owner supplies it (Section 4.6).

---

## 2. Host facts

| Fact | Value | Why it matters |
|---|---|---|
| Host OS | Bazzite 44 (`bazzite-nvidia-open`), kernel 7.2, hostname `tower` | bootc/immutable; only `/var` and `$HOME` are writable |
| Owner's working shell | distrobox `dev` (Fedora 43) | `podman` and `docker` are **aliases to `distrobox-host-exec`**, so all container commands already run on the host. Shell aliases don't apply inside scripts (Section 4.4) |
| Podman | 5.8.4, rootless, overlay, netavark, **pasta** available, SELinux **enabled** | `:Z` labels required on bind mounts; pasta means all container egress appears on the host as the user's `pasta` process |
| uid map | `0→1000`, `1–65536→524288+` | With `--userns=keep-id` the container's uid 1000 == host uid 1000, so the bind-mounted project dir is writable by the non-root user without chown games |
| tmux | 3.7c on host and in distrobox | Entry script works from either side |
| `just` | on host | bazzite-tower uses a `Justfile`; reuse the convention |
| `gh` | not on host; 2.87.3 in the `dev` distrobox (`/usr/bin/gh`) | Agent containers still need their own copy; corrected 2026-09-22, the Phase 0 table wrongly said it was absent everywhere |
| `claude` | 2.1.278, native installer (`~/.local/share/claude/versions/2.1.278`) | Installer accepts an exact version arg: `install.sh 2.1.278` — verified by reading the script |
| `codex` | `@openai/codex` 0.155.1 via npm | Ships a platform binary behind a `#!/usr/bin/env node` shim, so node is a **runtime** dependency (corrected 2026-09-22; on the node-less host `codex --version` fails) |
| `pi` | `@earendil-works/pi-coding-agent` 0.87.1 on npm (corrected 2026-09-22: the Phase 0 pin `@mariozechner/pi-coding-agent` 0.73.1 had been deprecated in favour of this package since 2026-05-07; Renovate's dashboard caught it) | Needs node at runtime; `pi-flow` peer-depends on this package, which is why it appeared in the Phase 1 tree |
| `pi-flow` | `@kky42/pi-flow` 3.1.3 on npm (owner confirmed 2026-09-21) | A library consumed by `pi`; ships **no executable**, so it is verified with `npm ls -g`, not `--version` |
| ghcr.io | not logged in on Tower | Local-only is the zero-setup option (Section 3.3) |
| Existing `agent-*` images | none | Clean namespace |
| Credentials on host | `~/.claude/.credentials.json`, `~/.codex/auth.json`, `~/.config/gh/hosts.yml` (all mode 0600) | "No `$HOME` mounts" means none of these reach the container — Section 4.1 |

**Meute today** (`lib/engines.sh`) invokes `claude -p` and `codex exec -s
workspace-write` directly on the host inside a git worktree. It has no
container code path yet. That is good news: the tagging contract defined
here has no legacy consumer to break, and Meute's future container path can
be written against it from the start.

**bazzite-tower's firewall** is OpenSnitch (daemon-only, `proc` monitor,
`DefaultAction: allow` during rollout, Snitchwatch as UI). It is a
per-process application firewall on the host. Section 4.2 explains why it is
the second layer, not the first, for container egress.

---

## 3. Answers to the open questions

### 3.1 Rebuild / drift cadence → **content-triggered, with a visible staleness check; no timer**

- Every image gets a label `org.atelier.source-sha=<sha256 of the
  Containerfile(s) that produced it>` at build time.
- `agent-enter.sh` compares that label against the current Containerfile
  hash before attaching. Mismatch → print a one-line warning and continue.
  It **never** auto-recreates a persistent container: that container holds
  the owner's session state, which is the whole point of `sleep infinity`.
- `agent-enter.sh --rebuild <project>` is the explicit path: rebuild image,
  stop and remove the old container, create fresh.
- Base image refresh (OS CVEs) is a Containerfile change too, because the
  `FROM` line is digest-pinned. Bumping that digest is the "schedule": do it
  when you'd bump any other pin. `bazzite-tower` already runs Renovate for
  exactly this; if Atelier lands on GitHub, the same `renovate.json` pattern
  covers `FROM` digests and the npm version `ARG`s for free.
- Meute's ephemeral containers are `--rm`, so drift there is purely "which
  tag did it pull" — answered in 3.2.

Rejected: a weekly rebuild timer. It would rebuild images nobody changed,
and a rebuild that lands while a persistent container is mid-session gains
nothing because the running container is unaffected anyway.

### 3.2 Tag / version scheme → **humans track `latest`, Meute pins an immutable tag, digest recorded alongside**

Every build of `containers/<project>/` produces three tags on one image:

| Tag | Mutable? | Consumer |
|---|---|---|
| `agent-<project>:latest` | yes | `agent-enter.sh`, the owner |
| `agent-<project>:<YYYYMMDD>` | by convention, no | humans reading `podman images` |
| `agent-<project>:g<atelier-short-sha>` | no | **Meute's pin** |

This mirrors bazzite-tower's `{latest, YYYYMMDD, sha}` set minus the
`latest.YYYYMMDD` variant, which only exists there because of the
two-kernel matrix.

Rules added after Phase 1 review:

- The `g<sha>` tag is emitted **only** when `HEAD` resolves and the working
  tree is clean. Otherwise the build omits it and says why. A placeholder
  such as `gnogit` would be a mutable tag wearing an immutable name.
- The triple applies to **agent images** (`agent-base`, `agent-<project>`).
  The egress proxy image is `atelier-egress:latest` only; nothing pins it.

Meute records the `g<sha>` tag **and** the resulting `sha256:` digest in
its manifest. The tag is what a human reads and bumps; the digest is what
the runner asserts against `podman image inspect` before dispatch, so a
rebuild that silently reused a tag fails loudly instead of running on an
image nobody reviewed. Meute pinning `latest` was rejected: the whole reason
this is a separate repo is that daily-driver changes must not reach the
dispatcher until someone bumps a pin.

Local-only builds (3.3) do not weaken this: `podman build` produces a stable
digest for a stable input set, and `podman image inspect --format
'{{.Digest}}'` reports it without any registry involved.

### 3.3 Registry → **local-only now; the Containerfiles are written so pushing to `ghcr.io/bearyjd/` later is one `just push`, not a redesign**

- Both consumers run on Tower. There is no second machine that needs to
  pull, so a registry adds a login, a CI workflow, and a public image
  containing the exact pinned CLI versions, for no consumer.
- Images are named `localhost/agent-<project>` implicitly (Podman's default
  for unqualified local builds). Nothing in `agent-enter.sh` or the Meute
  contract should embed `localhost/`; use the bare `agent-<project>` name so
  a future `ghcr.io/bearyjd/agent-<project>` needs only a
  `registries.conf` search entry or a one-line variable change.
- Trigger to revisit: the moment a second host (the bazzite-tower docs
  mention "the P1") needs the images, or Meute moves off Tower. At that point
  copy bazzite-tower's `build.yml` (metadata-action tags, cosign signing)
  and its `renovate.json`.

---

## 4. Gaps the PRP does not cover

These are ordered by how much they change Phase 1. 4.1 and 4.2 are
design decisions; 4.3 and 4.4 are host facts the build agents must be told;
4.5 and 4.6 are inputs only the owner can supply.

### 4.1 Credentials — the "no `$HOME` mounts" rule needs an exception mechanism (decision required)

`claude`, `codex`, and `gh` are useless without auth, and all three keep it
under `$HOME`. The rule is right; it just needs a named carve-out.

**Recommendation:** one named volume per tool, mounted read-write at the
tool's expected path, populated once by a `just auth` recipe that copies the
three files listed in Section 2 into the volumes.

```
atelier-auth-claude  → /home/agent/.claude       (credentials + settings)
atelier-auth-codex   → /home/agent/.codex
atelier-auth-gh      → /home/agent/.config/gh
```

Why volumes and not bind mounts of the host files: a bind mount of
`~/.claude` is a `$HOME` mount by another name (it carries history,
projects, plugins, MCP config), and a bind mount of just the credentials
file breaks when the CLI rotates the OAuth token by rename-over-write.
Volumes are owned by the container's uid, are invisible to other
containers, and can be wiped with one `podman volume rm`.

Why not `podman secret` / API-key env vars: the owner is on a subscription
(OAuth), not API billing; Meute's whole cost model (PRP-001) is "work the
subscription already paid for". API keys would change that model.

**Trade-off the owner should know:** an agent inside the container can read
its own OAuth token. This is true of every agent sandbox that uses
subscription auth, including today's on-host Meute. The container reduces
what else that token can be combined with (no SSH keys, no browser
profiles, no other repos), which is the actual security gain.

**Rootless ownership constraint (found in Phase 1, verified by two
reviewers):** a file written into a volume by `podman volume import` lands
under the default user namespace and shows up as uid 999 inside a
`--userns=keep-id:uid=1000,gid=1000` container, so the agent user cannot
read a 0600 credential. The import must therefore run *under the same
flag set the containers use*: stream the tar into `podman run -i
--userns=keep-id:uid=1000,gid=1000 ... tar -x`. `just auth` does this via
`scripts/auth-import.sh`, recreates each volume first so a re-run replaces
rather than accumulates, and exits non-zero if nothing was imported. The
smoke test exercises the same script with a dummy file and a throwaway
volume.

**Shadowing:** Podman copies image content into a volume only while the
volume is empty. Once `atelier-auth-claude` is populated, anything the
image placed under `CLAUDE_CONFIG_DIR` is hidden. This is intended: the
volume is the whole Claude state, not just the token.

**GitHub credentials are split by consumer (Meute PRP-004 §5, accepted).**
`atelier-auth-gh` holds the owner's interactive `hosts.yml` and is mounted
only by `agent-enter.sh`; an unattended process must never see it, since
it can push to every repo the owner can write to. Two further volume names
are reserved in the contract for Meute to populate with owner-minted
fine-grained PATs: `atelier-auth-gh-publish` (fleet repos only,
`contents:write`, `pull_requests:write`; mounted by the publish stage only)
and `atelier-auth-gh-review` (`contents:read`, `pull_requests:write` for
comments, `checks:read`). `scripts/auth-import.sh <volume> <file>` is
generic so any of the five volumes can be filled the same way.

**OAuth refresh race (open, owner decision pending).** Meute's log already
shows `Failed to refresh OAuth token: another Claude Code process is
refreshing it` with everything on the host sharing one
`~/.claude/.credentials.json`. If the provider rotates refresh tokens on
use, a *copied* volume and the host file will invalidate each other. The
cleaner design is not to copy at all: run the CLI's own login flow once
inside a container with the volume mounted (`claude` and `codex` both
support a headless URL-paste login), so each volume holds its own
independent token. `just auth` copies today because it needs no
interaction; a `just auth-login` recipe is the Phase 2 follow-up if
Meute's test with an interactive session open shows invalidation. Nothing
in the smoke test can cover this without real credentials.

**Ephemeral Meute containers** mount `atelier-auth-claude` and
`atelier-auth-codex` read-write (both CLIs write to their dirs) and one of
the two `gh-*` volumes read-only. The names are Atelier's contract and go
in the README; the wiring is Meute's.

### 4.2 Egress allow-listing — `--cap-drop=ALL` rules out in-container firewalling; use an internal network plus a proxy (decision required)

The obvious implementation (nftables/iptables inside the container, as
Anthropic's own devcontainer does) needs `CAP_NET_ADMIN`, which the PRP
forbids. OpenSnitch on the host can't do it either: with rootless netavark
every container's traffic exits through one `pasta` process per container,
and OpenSnitch's `proc` monitor rules match on process path, so it cannot
tell `agent-meute` from `agent-carnet`, and it is `DefaultAction: allow`
until Snitchwatch is fully rolled out.

**Recommendation:** two network profiles, selected per invocation.

- `none` — `--network=none`. For runs that never call a model: an
  in-container auth preflight (`claude auth status`, `codex login
  status`), a local build or test step. Meute's review (PRP-004 §5)
  corrected the Phase 0 assumption that this could be its default: every
  Meute engine run is a `claude -p` or `codex exec` call, so every engine
  run is `proxied` and the base allow-list below is load-bearing on day
  one.
- `proxied` — the agent container joins an `--internal` Podman network
  (no route out). One long-lived `atelier-egress` container sits on both
  that network and the default one, running a CONNECT-only forward proxy
  with a host allow-list. Agent containers get
  `HTTPS_PROXY=http://atelier-egress:3128` and `NO_PROXY=`. `claude`,
  `codex`, `gh`, `git`, `npm`, `pip`, and `cargo` all honour it. No TLS
  interception, no CA to install: the proxy sees only the CONNECT hostname
  and either allows or refuses.

The Phase 1 "hook point" is therefore: the `HTTPS_PROXY`/`HTTP_PROXY`
`ENV` lines in `agent-base` (value injected at `podman run`, not baked),
plus `containers/egress-proxy/` holding the proxy Containerfile and
`allowlist.txt`. The base allow-list is `api.anthropic.com`,
`statsig.anthropic.com`, `api.openai.com`, `chatgpt.com`, `auth.openai.com`,
`github.com`, `api.github.com`, `objects.githubusercontent.com`,
`codeload.github.com`. Per-project overlays append (e.g. `registry.npmjs.org`,
`pypi.org`, `files.pythonhosted.org`) via a second allow-list file the
proxy concatenates. Exact hostnames for the Claude and Codex OAuth refresh
flows are *unverified*. Confirming them needs real credentials in a
volume and one `claude -p` / `codex exec` call through the proxy with
tinyproxy logging on. That is a `just auth` run, which is the owner's
call because of the refresh-race risk in §4.1. It blocks Meute's Phase 2
gate, not Atelier's Phase 1.

Findings from Phase 1 that amend this section:

- A container joined to both an `--internal` network and the default
  bridge cannot resolve public names: aardvark-dns on the internal network
  answers NXDOMAIN authoritatively and glibc stops there. `--dns=<public
  resolver>` on the proxy container is honoured ahead of the injected
  server and fixes it. Bind-mounting a `resolv.conf` was tried first and
  rejected: it needed a shared `:z` relabel of a tracked file and dropped
  container-name resolution.
- The proxy's `Allow` is narrowed to the internal network's subnet, which
  is pinned in the Justfile so recreating the network cannot silently
  change it. An RFC1918-wide `Allow` let every other container on the host
  use the proxy.
- `statsig.anthropic.com` returned NXDOMAIN on public DNS on 2026-09-21
  and is removed from the base list until the telemetry host is confirmed.
- Proxy DNS ordering (found in Phase 2): when a container joins both the
  default bridge and `atelier-internal`, Podman writes the aardvark
  entry ahead of the `--dns` entries on roughly one start in four, and
  its authoritative NXDOMAIN then hides every public name. A retry loop
  in `egress-up` still let 1 start in 10 report success with dead DNS.
  Rewriting `/etc/resolv.conf` from the entrypoint is impossible: under
  `--read-only` it is a kernel read-only mount. Fix at the network level:
  `atelier-internal` is created with `--disable-dns`, the proxy gets a
  static `--ip` in the pinned subnet, agent containers get
  `--add-host atelier-egress:<ip>` so `HTTPS_PROXY=http://atelier-egress:3128`
  is unchanged, `egress-up` health-checks a public lookup after start, and
  the smoke test asserts it. The proxied run flags therefore gain one
  `--add-host` entry; Meute's contract table records it.
- Proxy method invariant, as actually implemented: the hostname
  allow-list applies to every request; CONNECT is limited to port 443;
  a plain-HTTP forward request to an *allow-listed* host is relayed to
  whatever port it names. tinyproxy has no directive to refuse non-CONNECT
  methods (`ReverseOnly` was tried and breaks CONNECT outright). The gap is
  confined to hosts already trusted, and moving to Squid for method gating
  is the recorded upgrade path if it ever matters.
- The proxy's generated filter lives on a tmpfs with `mode=1777`, not
  `0700,uid=999`: Podman's `--tmpfs` rejects `uid=`/`gid=` options. Safe
  because the container runs one process at one uid and is otherwise
  `--read-only`.

Accepted residuals (Codex adversarial pass, 2026-09-21, `docs/reviews/phase1-codex.md`):

- A CONNECT proxy authorises the requested hostname and then tunnels
  opaque TLS. An agent can CONNECT to an allow-listed host on a shared CDN
  and present SNI for a different tenant on the same address. Closing
  this needs TLS interception or an SNI-validating proxy; neither is
  worth its cost here. Accepted: the allow-list bounds *which addresses*
  are dialled, not which tenant answers.
- The proxy filters by name before resolution and applies no policy to
  the resolved address, so DNS rebinding of an allow-listed name could
  point at a private range. Accepted for now; Squid's `dst` ACL is the
  upgrade path if the allow-list ever grows beyond first-party API hosts.

OpenSnitch remains the second layer: the `pasta` process for
`atelier-egress` can be given a single narrow OpenSnitch rule once
`DefaultAction` flips to `deny`, and every other `pasta` process (the agent
containers on `--internal` networks) never generates a connection to rule
on.

Rejected: `--network=slirp4netns` or pasta options. Neither filters by
destination.

### 4.3 SELinux and user namespaces — mandatory `podman run` flags (Phase 1/2 input, no decision)

Bazzite runs SELinux enforcing. Without these the project bind mount is
`EACCES` from inside the container and the security review would rightly
fail the diff.

```
--userns=keep-id:uid=1000,gid=1000   # container uid 1000 == host uid 1000
--volume "$PROJECT_DIR:/work:Z"      # private SELinux relabel, only this dir
--cap-drop=ALL
--security-opt=no-new-privileges
--init                               # catatonit reaps zombies from exec'd shells
--pids-limit=2048
```

Verified on Tower with exactly this flag set on the cached `debian:12`
image: uid reports 1000, a write into the bind mount succeeds, the file
gets a `container_file_t` label, `CapBnd` is all zeros, `NoNewPrivs` is 1,
and with `--network=none` name resolution fails as intended.

`agent-base` must therefore create its non-root user as **uid 1000, gid
1000** (name `agent`) so `keep-id` maps cleanly. `:Z` (private label) not
`:z` (shared). The Phase 0 rationale ("nothing else needs to read the
project dir while labelled") was wrong on this host: the `dev` distrobox
and the desktop container both mount `$HOME`. It does not matter, for a
reason verified in Phase 2: both run with `--security-opt label=disable`,
so SELinux labels are not consulted for them at all. `:Z` therefore
costs nothing here; `restorecon -R -v <dir>` undoes it if a labelled
process ever needs the tree back. Note `:Z` relabels the
directory on the host; that is reversible (`restorecon -R`) and is the
standard rootless-Podman practice on Fedora-family hosts.

`:z` (shared label) is not used anywhere in this repo. The one place it
appeared, the proxy's `resolv.conf` mount, was replaced by `--dns` flags.

**Read-only rootfs: verified and kept (Phase 2).** Agent containers run
`--read-only` with tmpfs at `/tmp`, `/home/agent/.cache`,
`/home/agent/.npm`, `/home/agent/.local/share` and `/home/agent/.config`,
with the three auth volumes mounted at their real paths (the `gh` volume
sits under the `.config` tmpfs and stays writable). All CLIs report their
versions, `git` works in `/work`, and `claude -p` reaches a clean
"not logged in" rather than a crash. `codex` prints a harmless
"could not create PATH aliases: Read-only file system" warning. Meute
can adopt the same set for its ephemeral containers; `--tmpfs` entries
do not appear in `podman inspect .Mounts`, so mount assertions are
unaffected. The egress proxy *does*
run `--read-only` with a tmpfs for its generated filter.

### 4.4 Execution context — `agent-enter.sh` must work from inside the distrobox (Phase 2 input, no decision)

The owner's interactive shell is the `dev` distrobox. `podman` works there
only because of a shell alias, and aliases are not expanded in scripts.
The script needs:

```bash
if [[ -f /run/.containerenv ]] && command -v distrobox-host-exec >/dev/null; then
  PODMAN=(distrobox-host-exec podman)
else
  PODMAN=(podman)
fi
```

Verified: `distrobox-host-exec podman exec -it …` passes the TTY through
correctly. tmux can run on either side; recommend the script creates the
tmux session **where it is invoked** (so it appears in the owner's existing
tmux server) and only the `podman` calls cross to the host. Also honour
`ATELIER_PODMAN` as an override for anyone who wraps podman differently.

### 4.5 `pi-flow` — resolved: `@kky42/pi-flow` 3.1.3

npm has at least five unrelated packages called `pi-flow`; the bare
`pi-flow` (1.0.0) is a web analytics library. The owner confirmed the
intended one is **`@kky42/pi-flow`** (3.1.3, "multi-backend subagents and
dynamic workflow orchestration for pi"). It goes into `agent-base`
alongside `pi`, pinned as `PI_FLOW_PKG=@kky42/pi-flow`
`PI_FLOW_VERSION=3.1.3`. Phase 1 should confirm it installs cleanly with
`--ignore-scripts`; if it needs a postinstall, allow it for that one
package only and say so in the Containerfile.

### 4.6 Reference `agent-enter.sh` is not on this machine (owner input required)

Searched `~/Documents/vibe-code` (all projects), `~/.local/bin`, `~/bin`,
`~/.claude`. No file or mention. Per PRP Section 5, Phase 2 must port the
existing script, not re-derive it. **Owner: paste it into
`scripts/agent-enter.sh` (or anywhere) before Phase 2 starts.** The script
will need the 4.3 flags and the 4.4 wrapper regardless of what it currently
contains, so the Phase 2 diff is expected even against a good reference.

---

## 5. Repository structure — confirmed, with four additions

The PRP layout is kept. One structural question was considered and
resolved in the PRP's favour:

**Should per-project overlays live in each project's repo instead of
`containers/<project>/`?** No. Meute's agents write to project repos. If the
overlay lived there, an agent could edit the definition of its own sandbox
and have the next dispatch build it. Keeping overlays in Atelier, a repo
Meute never writes to, is what makes the consumption boundary a security
boundary and not just a tidiness preference. This should be stated in the
README so nobody "simplifies" it later.

**The exception is this repository itself.** An agent whose `/work` is
Atelier can edit `allowlist.txt`, the Justfile or a Containerfile, and the
change takes effect the next time the owner runs a build, which is exactly
the trusted moment. Atelier is therefore never opened inside an Atelier
container. Phase 2: `agent-enter.sh` refuses to bind this repo as `/work`
without an explicit override flag.

Additions:

```
atelier/
├── AUDIT.md                          # this file
├── docs/prp/atelier-prp.md
├── containers/
│   ├── agent-base/Containerfile
│   ├── egress-proxy/                 # NEW — 4.2: proxy Containerfile + allowlist.txt
│   └── <project>/
│       ├── Containerfile
│       └── allowlist.txt             # NEW, optional — per-project egress additions
├── scripts/
│   └── agent-enter.sh
├── tests/
│   └── smoke.sh                      # NEW — asserts the security posture (see below)
├── Justfile                          # NEW — build, build-all, auth, push (future)
└── README.md                         # includes the Meute contract: names, tags, volumes
```

`tests/smoke.sh` follows bazzite-tower's pattern and is what makes the
Codex adversarial review in Phase 1 checkable rather than opinion-based.
It runs the built image with the exact Phase 2 flags and asserts: uid is
1000 and not root; `capsh --print` shows an empty bounding set;
`/proc/self/status` has `NoNewPrivs: 1`; `/home/agent` contains no host
files and, in a run that mounts the three auth volumes, nothing else is
mounted under it; under the `none` profile a curl to a raw public IP
fails, not merely DNS; on `atelier-internal` with no proxy variables a
curl to a raw public IP fails (no route out); through the proxy,
`api.github.com` succeeds and a non-listed host is refused **by the
proxy** (HTTP 403 and a "Proxying refused on filtered domain" log line),
using a resolvable substring probe such as `gist.github.com`; the auth
import script lands a dummy file readable by uid 1000 at mode 600; no
setuid files exist; `claude --version`, `codex --version`, `pi --version`
print the pinned versions, `gh` and `git` are present and parse, and
`@kky42/pi-flow` resolves in `npm ls -g`. A negative assertion that
passes on any failure is worth less than no assertion: two such were
found in the first build.

**Naming:** the working directory is `atelier-harness/` and the PRP calls
the repo `atelier/`. The owner did not choose, so the build defaulted to
`atelier-harness` (baked into the `org.opencontainers.image.source`
label). Renaming before the first push is a one-line label change.

---

## 6. Phase 1 inputs (for the Sonnet build prompt)

- Base image: `registry.fedoraproject.org/fedora:44` pinned by digest at
  build time (matches the host and the `dev` distrobox; `gh` and `nodejs`
  are in Fedora's repos, so no third-party repo keys — the same
  pin-and-verify stance bazzite-tower takes). Debian 12 is already cached
  locally and would be smaller; if the reviewer prefers it, the only change
  is `gh` coming from GitHub's apt repo with its key pinned by fingerprint.
- Pins, as `ARG`s so Renovate can bump them later:
  `CLAUDE_VERSION=2.1.278`, `CODEX_VERSION=0.155.1`,
  `PI_VERSION=0.73.1`, `PI_FLOW_PKG=@kky42/pi-flow`, `PI_FLOW_VERSION=3.1.3`.
  `claude` via the native installer with the version argument (verified
  to accept `X.Y.Z`); `codex` and `pi` via `npm install -g <pkg>@<ver>`
  with `--ignore-scripts` unless a package proves it needs a postinstall.
- User: `agent`, uid 1000, gid 1000, home `/home/agent`, `WORKDIR /work`.
- `ENTRYPOINT` unset; `CMD ["sleep","infinity"]`.
- `ENV HTTP_PROXY= HTTPS_PROXY= NO_PROXY=` declared empty (hook point, 4.2).
- Labels: `org.atelier.source-sha`, `org.opencontainers.image.source`,
  `org.opencontainers.image.created`.
- No toolchains, no `sudo`, no `dnf` cache left in the image. `sudo` is
  removed in the same `RUN` as the install (so its bytes leave the image)
  with `--setopt=protected_packages=`, and only `sudo` goes: pam and
  authselect stay because the toolchain depends on them. Setuid bits are
  stripped from every remaining binary and the build asserts `sudo` is
  gone.
- `gh` and `git-core` are **not** pinned; they ride the base digest.
  More generally, `dnf install` resolves mutable repository metadata, so
  two builds of one Containerfile can differ in package content.
  `org.atelier.source-sha` therefore means "built from these inputs", not
  "bit-identical". Accepted; a locked RPM snapshot is out of proportion
  for this repo.
- Pins are exact `ARG`s and Renovate (`renovate.json`, app enabled
  2026-09-22) tracks the Fedora 44 digest and the npm pins; the dashboard
  also surfaces deprecations, which is how the `pi` pin was caught.
- The Claude installer bootstrap fetched a mutable `latest` binary before
  installing the pinned version (Codex finding). Fixed by downloading the
  exact-version binary directly and verifying a sha256 recorded in the
  Containerfile; the vendored script is no longer executed.
- npm installs are locked with a committed lockfile and `npm ci
  --ignore-scripts`, so the transitive graph is pinned, not just the three
  top-level versions. `npm audit` on the 2026-09-21 lockfile reported
  open advisories against `@mariozechner/pi-coding-agent` 0.73.1 and its
  transitive `extract-zip`, with no fixed version in range. The reason was
  that the package itself was deprecated: its successor
  `@earendil-works/pi-coding-agent` (0.87.1 as of 2026-09-22) audits
  clean. The pin moved to the successor; the Phase 1 "hoisting picked the
  wrong package" workaround, which forced the `pi` symlink back to the
  deprecated package, was the wrong call and is reversed.
- `ENV CLAUDE_CONFIG_DIR=/home/agent/.claude` so all Claude state lives in
  the auth volume. Proxy variables are declared in both cases
  (`HTTPS_PROXY` and `https_proxy`): curl ignores uppercase `HTTP_PROXY`.
- The Claude installer script is vendored into the repo and hash-checked
  at build time; only the binary it downloads is fetched, and the script
  itself verifies that binary's SHA-256. A live `curl | bash` made two
  builds of one Containerfile able to run different installer logic.

## 7. Phase 2 inputs (for the Sonnet port prompt)

- Naming: container `agent-<project>`, tmux session `agent-<project>`,
  image `agent-<project>:latest`. Project name derived from the directory
  basename unless given explicitly.
- `podman run` flags exactly as 4.3, network per 4.2 (`proxied` default
  for interactive use, `none` selectable), auth volumes per 4.1.
- Podman wrapper per 4.4.
- Staleness warning per 3.1; `--rebuild` flag per 3.1.
- Tag set per 3.2 emitted by the `Justfile` build recipe, never by the
  entry script.

---

## 8. Decisions needed from the owner before Phase 1

1. **4.1** Auth via named volumes populated by `just auth` — agree?
2. **4.2** Egress via internal network + CONNECT proxy, two profiles — agree?
3. ~~**4.5** Which `pi-flow`?~~ Resolved: `@kky42/pi-flow` 3.1.3.
4. **4.6** Supply the reference `agent-enter.sh`.
5. **Section 5** Repo name: defaulted to `atelier-harness`; say so if you want `atelier`.

Items 1 and 2 are recommendations with a stated default; if unanswered,
Phase 1 proceeds with them as written. Item 4 blocks Phase 2.

---

## 9. Phase 1 outcome (2026-09-22)

Built by a Sonnet executor, reviewed by the `security-reviewer` agent and
by the `critic` agent standing in for Codex, which was quota-blocked. Both
reports are under `docs/reviews/`. **A Codex adversarial pass is still
owed** per the PRP's review table; run it once quota returns.

First build claimed 18/18 smoke passes. The reviews found:

- Blocking: `just auth` produced credentials owned by uid 999 under
  `keep-id`; no container could authenticate. Fixed per §4.1.
- Two smoke assertions that could never fail (the `$HOME` mount check and
  both proxy negatives). Fixed per §5.
- A mutable `gnogit` tag posing as the immutable Meute pin. Fixed per §3.2.
- Proxy `Allow` open to all RFC1918; `resolv.conf` shared relabel;
  `egress-up` not applying config changes; a false "verified" comment
  about the sudo cascade; eleven setuid binaries (inert under
  `no-new-privileges`, now stripped); unpinned installer script.

All items were sent back as one fix round. An independent `verifier`
agent then re-ran, not re-read, every check: 24/24 smoke assertions passed at that point (27/27 after the Codex round),
both previously vacuous assertions were shown to fail against a real
`$HOME` mount and a real proxy refusal, the auth import lands as
`600 agent:agent` under the full flag set and replaces on re-run, the
default-bridge path to the proxy now returns 403 where it returned 200,
and an invalid allow-list entry makes the proxy exit non-zero. Every
finding is VERIFIED-FIXED except the plain-HTTP relay, which is
DEFERRED-BY-DECISION and documented as above.

The Codex adversarial pass ran on 2026-09-21 21:40 once quota returned
(`docs/reviews/phase1-codex.md`): 4 HIGH, 4 MEDIUM, 5 LOW. Three HIGHs
are accepted residuals recorded in §4.2 and §6 (CDN co-tenancy, dnf
metadata, DNS rebinding). Fixed in a second round: exact-version Claude
binary download, npm lockfile, allow-list validator rejecting IP
literals, `egress-up` waiting for a running proxy and smoke refusing to
skip proxy checks by default, `{{project}}` shell-quoting and name
validation in the Justfile, presence checks requiring exit 0, pi-flow
exact-version assertion, all five capability sets asserted zero,
two-probe auth re-import test, and `--network=none` on the credential
extraction container.

**Phase 1 is complete.** Carried to Phase 2: `--read-only --tmpfs` for
agent containers; `agent-enter.sh` refusing this repo as `/work`; a
`just auth-login` recipe if Meute's refresh-race test shows copied tokens
invalidate each other. Owner items: run `just auth` (or decline, see
§4.1), mint the two Meute PATs, supply the reference `agent-enter.sh`,
and re-run the Codex adversarial pass when quota returns.

## 10. Phase 2 outcome (2026-09-21, evening)

The reference `agent-enter.sh` never surfaced; the owner said to proceed,
so the script was derived from the PRP's description of the three-layer
state machine. Built by a Sonnet executor with the test written first.
Delivered: `scripts/agent-enter.sh`, `scripts/source-sha.sh` (one
manifest helper shared by the Justfile and the staleness check so they
cannot drift), `containers/example/` as the reference overlay, `just build
<project>` emitting the §3.2 tag set, a per-project allow-list union
staged into the proxy image, `tests/smoke-enter.sh` (23 assertions at first build, 45 after the fix round:
flags via `podman inspect`, exact mounts, both network profiles, reuse,
exit-code propagation, staleness warning present and absent, `--rebuild`,
self-refusal, tmux session creation and reuse on a private socket), and
README sections for the overlay convention and entering a project.

Not verifiable headless: a real `tmux attach` to a controlling terminal.
The owner's first interactive `agent-enter <project>` is that test.

Review lane results (`docs/reviews/phase2-code-review.md`,
`docs/reviews/phase2-codex.md`): code-reviewer found 1 CRITICAL, 6 HIGH,
9 MEDIUM, 5 LOW and blocked; Codex found 2 HIGH, 4 MEDIUM, 2 LOW, largely
the same defects. The CRITICAL: the self-refusal compared path strings,
and `/home/user` and `/var/home/user` are one inode under two canonical
names on this host, so entering Atelier by the other name bypassed the
boundary. The HIGHs: a reused container silently kept its old `/work`
and network profile; the auth-volume emptiness probe ran the overlay
image with a credential volume and no hardening on the default network;
a `.` in a project name broke tmux targeting permanently; the tmux attach
path skipped the whole container layer including the §3.1 staleness
check; `REPO_ROOT` was not canonicalised. Also: the `--allow-self` test
relabelled this repository. All sent back as one fix round. The
executor also found on its own that the project-name sanitizer's
rejection never stopped execution (bash does not propagate a failing
command substitution under `set -e`), and reset this repository's
SELinux labels, which the old test had left relabelled.

**Final verification (2026-09-21 23:20 EDT, `docs/reviews/final-verification.md`):**
an independent verifier re-ran both suites (27/27 and 45/45) and
reproduced every fix live: the inode-based self-refusal on the path
alias, a symlinked parent and `$HOME`; exit 4 on `--dir` and `--network`
mismatch; exactly one container created per entry; dotted-name tmux
round-trip; recreation of a container removed behind a live session;
the exact-version Claude binary and npm lockfile; validator rejection of
IP literals and wildcards; `--network=none` on credential extraction;
5/5 proxy recreations with working DNS and no retry logic left; no
`|| true` in production scripts; repo labels reset; README contract
complete. **Phases 1 and 2 are complete against this audit.**

Still open, all owner items: run `just auth` or choose the per-volume
login design (§4.1); mint Meute's two PATs; the first real interactive
`agent-enter <project>` with a terminal (the tmux attach itself cannot be
exercised headless); a `just auth-login` recipe if Meute's refresh-race
test shows copied tokens invalidate; bump the `pi` pin when upstream
ships fixes for its open advisories (§6). Accepted residuals: plain-HTTP
relay to allow-listed hosts, CDN co-tenancy through CONNECT, mutable dnf
metadata, DNS rebinding (§4.2, §6).
