# Atelier

Shared container infrastructure for AI coding agents (`claude`, `codex`,
`pi`, the latter extended by the `pi-flow` library), used by two
independent consumers on the same host:

- **The owner**, working interactively via a persistent container attached
  to with `podman exec -it`.
- **Meute**, a dispatcher that pulls the same tagged images for ephemeral,
  autonomous build/test containers.

Atelier owns image definitions and the entry mechanism. It has no
knowledge of Meute, spare-quota dispatch, or pipeline stages -- those
concepts don't belong here. Full design rationale and the audit of the
host this targets live in `AUDIT.md` and `docs/prp/atelier-prp.md`.

## Consumption boundary

Meute pins to Atelier's image tags and never edits a Containerfile or the
entry script. A daily-driver change here doesn't touch Meute until the pin
is bumped, and Meute's dispatcher never destabilizes what the owner uses
interactively.

**Per-project overlay images live in this repo** (`containers/<project>/`),
not in each project's own repository, even though that would seem more
local. Meute's agents write to project repos as part of normal operation.
If a project's sandbox definition lived inside that project, an agent
could edit the definition of its own sandbox and have the next dispatch
build it -- silently escalating what that agent can do. Keeping overlays
in Atelier, a repo Meute's agents never write to, is what makes the
consumption boundary an actual security boundary rather than a tidiness
preference.

**This repo is inside its own trust boundary and must never be `/work`
inside an Atelier agent container.** The reasoning above holds for every
repository except this one: an interactive agent with `atelier-harness`
bound at `/work` could edit `containers/egress-proxy/allowlist.txt`,
`Justfile`, or any Containerfile, and the change takes effect silently the
next time the owner runs a build or `egress-up` -- exactly the trusted
moment the whole design exists to protect. Phase 2's `agent-enter.sh` is
expected to refuse binding this repository's own directory as `/work`
without an explicit override flag; if you need to edit Atelier from
inside a container anyway, mount it read-only.

## Meute contract

| What | Value |
|---|---|
| Image names | `agent-<project>` (per-project overlay images built `FROM agent-base`) |
| Tags per build | `agent-<project>:latest`, `agent-<project>:<YYYYMMDD>`, `agent-<project>:g<atelier-short-sha>` |
| Meute pins to | `agent-<project>:g<atelier-short-sha>`, plus the resulting `sha256:` digest asserted via `podman image inspect` before dispatch -- a rebuild that silently reused a tag fails loudly instead of running on an unreviewed image. |
| Humans read | `agent-<project>:latest` (mutable, tracks the daily driver) and `:<YYYYMMDD>` (by convention immutable) |
| Auth volumes | Five named volumes, never `$HOME` bind mounts (see below): `atelier-auth-claude`, `atelier-auth-codex` (both read-write, either consumer); `atelier-auth-gh` (the owner's interactive `hosts.yml`, mounted **only** by `agent-enter.sh` -- an unattended process must never see it, since it can push to every repo the owner can write to); `atelier-auth-gh-publish` and `atelier-auth-gh-review`, reserved for owner-minted fine-grained GitHub PATs that Meute populates and mounts read-only (scopes: AUDIT.md §4.1 -- `contents:write`/`pull_requests:write` on fleet repos only for `-publish`; `contents:read` + `pull_requests:write` for comments + `checks:read` for `-review`) |
| Network profiles | `none` (`--network=none`; for runs that never call a model at all -- an in-container auth preflight, a local build/test step) and `proxied` (joins the `atelier-internal` network behind the `atelier-egress` proxy; **every Meute engine run is `proxied`**, since every engine run is a `claude -p` or `codex exec` call). `atelier-internal` is created with `--disable-dns` (deterministic `/etc/resolv.conf`, see below), so the proxied profile also adds `--add-host atelier-egress:<ip>` -- the name is no longer resolvable by DNS on that network at all. |
| Proxy value | `HTTPS_PROXY=http://atelier-egress:3128` (and the same for `HTTP_PROXY`); `NO_PROXY=localhost,127.0.0.1` (and lowercase); only how the name resolves changed, from DNS to the static `--add-host` entry above |

Registry: local-only for now (images are unqualified `agent-<project>`,
resolved as `localhost/agent-<project>` by Podman). Nothing here embeds
`localhost/` explicitly, so publishing to `ghcr.io/bearyjd/` later is a
one-line change, not a redesign.

## Security posture

- Rootless Podman only. No `docker-ce`.
- `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id:uid=1000,gid=1000`.
- No `$HOME` mounts. Only the project directory is bind-mounted
  (`:Z`-labelled, private SELinux relabel), plus the five named auth
  volumes above.
- Network egress is allow-listed via `atelier-egress`, a forward proxy
  (tinyproxy) with a hostname allow-list -- no TLS interception, no CA to
  install. `--network=none` is available for runs that never call a model
  at all (an in-container auth preflight, a local build/test step); every
  Meute engine run (`claude -p` / `codex exec`) is `proxied`, so the
  allow-list is load-bearing from day one, not an optional hardening step.
  **The real invariant** (tinyproxy has no directive that lets us state
  this more strongly, verified empirically -- see
  `containers/egress-proxy/tinyproxy.conf` for the full account): the
  hostname allow-list applies to every request, whether it arrives as a
  CONNECT (the HTTPS path) or a plain forward-proxy request; CONNECT is
  restricted to port 443; plain-HTTP forward-proxy requests to an
  allow-listed host are **not** port-restricted, since tinyproxy's
  `ConnectPort` only governs the CONNECT method. This does not widen
  *which* hosts are reachable -- the allow-list still gates that -- only
  *how* an allow-listed host may be reached.
- `agent-base` ships no `sudo` and no setuid-root binaries (the packages
  that provide them, e.g. `passwd`/`su`/`mount`, stay installed as
  dependencies of the toolchain, but their setuid bit is stripped at
  build time), no toolchain-specific packages (those belong in
  `containers/<project>/`), and no dnf cache left in the image.

The exact `podman run` flag set is in `AUDIT.md` §4.3 and is what
`tests/smoke.sh` asserts against.

## Building

```sh
just build-base     # containers/agent-base -> agent-base:{latest,YYYYMMDD,g<sha>}
just build-egress   # containers/egress-proxy -> atelier-egress:latest
just build-all       # both
just build <project> # containers/<project> -> agent-<project>:{latest,YYYYMMDD,g<sha>}
```

## Overlay convention

A per-project image is `containers/<project>/`, built `FROM agent-base:latest`
and holding whatever toolchain that project's agent needs -- packages
`agent-base` deliberately does not ship (AUDIT.md §5/§6). `containers/example/`
is the reference to copy:

```
containers/example/
├── Containerfile    # FROM agent-base:latest; installs jq, ripgrep; USER agent last, no ENTRYPOINT
└── allowlist.txt    # optional: extra egress hosts this project's tools need
```

A Containerfile in this shape: switches to `USER root` only to install
packages (the same `dnf install -y --setopt=install_weak_deps=False ...`
flags `agent-base` itself uses, so an overlay doesn't silently pull in
weak/recommended deps the base avoids), sets its own
`org.atelier.source-sha`/`org.opencontainers.*` labels from the `ARG`s
`just build` passes in, and ends with `USER agent` -- no `ENTRYPOINT`,
since it inherits `agent-base`'s `CMD ["sleep","infinity"]` foreground
no-op that persistent containers need.

`just build <project>` produces the same three tags as `build-base`
(`agent-<project>:latest`, `:<YYYYMMDD>`, `:g<sha>` when `HEAD` resolves
and the tree is clean -- AUDIT.md §3.2), and requires `agent-base:latest`
to already exist.

Two consequences of that scheme, observed on the first day: a rebuild of
the same commit does **not** reproduce a digest (the build timestamp is a
label), so `latest` and `g<sha>` can point at different image IDs within
minutes of each other -- do not read `podman images` as "the g-tag is what
I just built". And because Meute asserts the digest, never force-retag an
existing `g<sha>` onto a new build: every Meute pin on it would decline
with image drift until someone runs its `image bump`, which is the
intended behaviour of an immutable tag. Its `SOURCE_SHA` manifest covers the overlay's own files
*and* every file under `containers/agent-base/` (enumerated at build time,
not a hardcoded file list, so it survives agent-base's own file set
changing shape -- it already has once, when the vendored installer script
was replaced by a direct binary download): a base rebuild that changes
what `agent-base:latest` contains marks every overlay built on top of it
stale too.

**The egress allow-list is a union across every project, not scoped per
container.** There is one shared `atelier-egress` proxy, not one per
overlay, so `just build-egress` concatenates the base allow-list
(`containers/egress-proxy/allowlist.txt`) with every
`containers/<project>/allowlist.txt` in this repo before building the
proxy image (staged into a named build context, not copied into the
tracked `containers/egress-proxy/` directory). A host one project's
overlay needs becomes reachable from *every* agent container on the
`proxied` network, including other projects' -- there is no per-project
isolation of the allow-list itself, only of which container gets which
image and mounts. `just egress-up` picks up an allow-list change the same
way it picks up any other `atelier-egress` rebuild: via the
`org.atelier.source-sha` label mismatch (see below).

## Running the egress proxy

```sh
just egress-up    # creates/refreshes the atelier-internal network + atelier-egress container
just egress-down  # tears both down
```

`egress-up` is convergent: it recreates the network if its subnet or DNS
setting has drifted from the pinned values, and recreates the container if
its `org.atelier.source-sha` label no longer matches the image it just
built (e.g. after editing `allowlist.txt`) -- editing the allow-list and
running `egress-up` again actually applies the change, it doesn't just
rebuild an image nobody is running.

**`atelier-internal` is created with `--disable-dns`.** Podman used to
order a container's `/etc/resolv.conf` nameservers non-deterministically
whenever it joined two networks, and `atelier-egress` joins both the
default `podman` network and this one -- roughly 1 in 4 fresh starts
landed with the internal network's own DNS entry ahead of the real
resolvers, and that entry answers an authoritative NXDOMAIN for public
hostnames, so the proxy silently had no working DNS. `--disable-dns`
removes the internal network's DNS entry entirely, so only the pinned
public resolvers ever reach `/etc/resolv.conf` -- deterministic, verified
over 10 consecutive `podman rm -f atelier-egress && just egress-up`
cycles with zero failures. The cost: nothing on `atelier-internal` can
resolve the `atelier-egress` name by DNS anymore, which is why the proxy
now runs at a pinned static IP (`egress_ip` in the Justfile) and
`agent-enter.sh`'s proxied profile adds a `--add-host` entry instead (see
"Entering a project" and the Meute contract table above).
`egress-up` also runs a single post-start health check
(`getent hosts api.github.com` inside the container, polled for a few
seconds) and fails loudly with the container's logs if it doesn't
resolve -- with DNS now deterministic, a failure here means something is
actually wrong, not an unlucky race worth retrying past.

`atelier-egress` runs with `--restart=always`. In **rootless** Podman that
only means "restart if the process dies while the user session is still
around" -- it does **not** survive a host reboot on its own. Surviving a
reboot needs `systemctl --user enable --now podman-restart.service` (or a
generated user unit for this container specifically); this repo does not
set that up for you.

## Populating auth volumes

```sh
just auth
```

`just auth` populates only the original three volumes --
`atelier-auth-claude`, `atelier-auth-codex`, `atelier-auth-gh` -- by
copying `~/.claude/.credentials.json`, `~/.codex/auth.json`, and
`~/.config/gh/hosts.yml`, owned by uid 1000 and readable under the real
`--userns=keep-id:uid=1000,gid=1000` flag set. The import logic lives in
`scripts/auth-import.sh <volume> <file>`, which streams the credential
file into a container using those exact flags rather than `podman volume
import`, whose extraction runs in a different user-namespace mapping and
produced files the agent user couldn't read. That extraction container
also always runs with `--network=none`: it only ever needs to write the
incoming tar stream to a volume, and the image it runs
(`$ATELIER_AUTH_IMAGE`, overridable -- `tests/smoke.sh` points it at a
throwaway image) has no legitimate reason to reach the network while a
credential is passing through it. Each run replaces a volume's contents
rather than adding to them, so a rotated token doesn't leave the old one
behind. This is a one-time (or re-run-when-rotated) step; it does not
bind mount `$HOME`.

`scripts/auth-import.sh` itself is generic -- it takes any volume name
and any source file, so it's also what populates
`atelier-auth-gh-publish` and `atelier-auth-gh-review` (see the Meute
contract table above) once the owner has minted the corresponding
fine-grained PAT. `just auth` intentionally does not do that step: those
two tokens are Meute's to request and rotate, not something copied
automatically off the owner's interactive session the way the other three
are.

**A populated auth volume shadows whatever the image put at that path.**
Podman only copies an image's own content into a named volume when the
volume is empty; once `just auth` has run, anything `agent-base` wrote
under e.g. `/home/agent/.claude` at build time is permanently hidden, with
no warning. This is intentional -- the volume is the source of truth for
credentials and settings -- but worth knowing before chasing a "my
settings didn't take" report.

## Entering a project

```sh
scripts/agent-enter.sh [--project NAME] [--dir PATH] [--network proxied|none]
                        [--rebuild] [--allow-self] [--no-tmux] [--] [command...]
```

`agent-enter.sh` is a three-layer state machine -- tmux session -> container
-> shell -- that creates whichever layer is missing and attaches to
whichever already exists:

- A tmux session named `agent-<project>` exists -> attach (`switch-client`
  instead, if already inside tmux).
- Else the container `agent-<project>` is running -> open a shell into it
  (`podman exec -it ... bash -l`, or the trailing `command...` in place of
  `bash -l`) inside a fresh tmux session, then attach.
- Container exists but stopped -> `podman start`, then the same.
- Neither exists -> `podman run -d` with the hardened flag set below, then
  the same.
- `--no-tmux` skips the tmux layer entirely and execs straight into the
  container -- for scripts and CI, not interactive use; a trailing command's
  exit code propagates directly.

Project name defaults to the sanitized basename of `--dir` (default
`$PWD`); `--project` overrides it. Validation (`scripts/valid-project-name.sh`,
also used by `just build`, so the two rules cannot drift) requires
`^[A-Za-z0-9._-]+$` and rejects `.`/`..`. If `containers/<project>/Containerfile`
exists it's built (`just build <project>`, if the image is missing) and
used; otherwise `agent-base:latest` is used with a printed notice. Every
`podman run` uses the AUDIT.md §4.3 flag set (`--userns=keep-id:uid=1000,gid=1000`,
`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--init`,
`--pids-limit=2048`, only `/work` plus the three auth volumes mounted),
plus `--read-only` with `--tmpfs` on `/tmp`, `.cache`, `.npm`,
`.local/share`, and `.config` -- verified against `claude`/`codex`/`pi`/`gh`
all working, `git status` in `/work`, and a clean (non-crashing) `claude -p`
auth error under that flag set (see the comment block at the top of the
script for the exact commands and results).

**`just egress-up` is a prerequisite**, not something `agent-enter.sh` runs
for you: the default network profile is `proxied`, and creating *or*
reattaching to a proxied container checks that `atelier-egress` is running
first (see the table below) -- there is no auto-start. `just smoke-enter`
needs it too, for the same reason.

Two network profiles, selected with `--network` (default `proxied`):

| Profile | Effect |
|---|---|
| `proxied` | Joins `atelier-internal`; adds `--add-host atelier-egress:<ip>` (the network is DNS-disabled -- see "Running the egress proxy" -- so this is how the name resolves, read fresh from the running proxy container each time, not a second copy of its pinned IP); sets `HTTPS_PROXY`/`HTTP_PROXY` (and lowercase) to `http://atelier-egress:3128`, `NO_PROXY=localhost,127.0.0.1`. Fails fast with a `just egress-up` pointer if `atelier-egress` isn't running -- checked before every proxied create *and* every proxied reuse or attach, not only at creation, so it never silently falls back to no egress control. |
| `none` | `--network=none`; no proxy env is injected. |

Before attaching -- on every invocation, including reattaching to an
already-running container, not only at creation -- the image's
`org.atelier.source-sha` label is compared against a fresh hash of its
current inputs (via `scripts/source-sha.sh`, the same helper `just
build`/`just build-base` use, so the two cannot compute it differently)
and, if a container already exists, its `.Image` is compared against the
image's current id. A mismatch prints a one-line warning naming
`--rebuild` and continues -- it never auto-recreates a container, since
that container holds session state. `--rebuild` is the explicit path:
kill the tmux session if present, rebuild the image (`just build
<project>` or `just build-base`), `podman rm -f` the container, and
recreate.

**Reusing a container refuses a request it doesn't match, rather than
silently ignoring part of it (exit 4).** If a container named
`agent-<project>` already exists, both its `/work` bind source and its
network profile are checked against what was just asked for. A different
`--dir` for the same `--project`, or a `--network` that doesn't match how
the container was created, is refused with a message pointing at
`--rebuild` or a different `--project` -- not silently kept as the first
directory, and not a per-invocation switch that only takes effect at
creation.

**This repository refuses itself as `--dir`, by filesystem identity, not
by string.** This host has more than one canonical path to the same
directory (verified: `/home/user/...` and `/var/home/user/...` share a
device+inode); `--dir` is compared against the repository by `stat`, not
by matching the resolved path text, so the alias doesn't bypass it, and
neither does a symlink pointing at the repository. A directory that
merely *looks* like a separate Atelier checkout (both
`scripts/source-sha.sh` and `containers/agent-base/Containerfile`
present, or its git directory resolves inside this repository -- e.g. a
worktree) is refused the same way. Either case exits 3; `--allow-self`
overrides it. Separately and unconditionally (no `--allow-self` override,
since that flag means "this is Atelier itself", not "mount my whole home
directory"), `--dir` equal to `$HOME`, `/`, `/etc`, `/usr`, or `/var` is
always refused, exit 3.

`scripts/source-sha.sh <dir> [extra-file...]` is the shared manifest-hash
helper behind all of this: `just build-base`, `just build`, and
`agent-enter.sh`'s staleness check all call it rather than each computing
the hash their own way, so the build side and the entry side cannot drift
apart.

**`:Z` relabels the project directory with a private SELinux MCS
category** (AUDIT.md §4.3's bind-mount flag). That is by design for the
project directory itself, but it is worth knowing the category is
*private*: any other confined process that also needs to read that
directory loses access until the label is restored
(`restorecon -R -v <dir>`, or `distrobox-host-exec restorecon -R -v <dir>`
from inside the `dev` distrobox). On this host specifically, the `dev`
distrobox and `claude-desktop` containers -- which both mount `$HOME` --
are **not** affected: both run with `label=disable` (verified via
`podman inspect --format '{{.HostConfig.SecurityOpt}}'`), meaning SELinux
enforcement is off for them entirely, so a project directory under
`$HOME` being relabelled by `agent-enter.sh` does not break their access
to it. A process that does *not* run with `label=disable` and shares a
project directory with an Atelier container would need the same
`restorecon` recovery. `tests/smoke-enter.sh` never relabels this
repository's own tree -- its self-refusal content check uses a throwaway
copy of the two marker files, specifically to avoid that (an earlier
version of the suite did relabel this repo via its `--allow-self` case;
fixed).

## Smoke test

```sh
just smoke
just smoke-enter   # scripts/agent-enter.sh: needs `just build example` and `just egress-up` first
```

Runs `agent-base:latest` with the hardened flag set and asserts the
security posture (non-root uid, all five capability sets -- `CapBnd`,
`CapEff`, `CapPrm`, `CapInh`, `CapAmb` -- empty, `NoNewPrivs`, no host
dotfiles under `/home/agent`, no `sudo`, no setuid-root binaries),
CLI presence with both an exit-0 check and a version-string grammar
check (not just "the output is nonempty" -- a missing binary's shell
error is nonempty too), `pi-flow`'s *exact* pinned version via
`npm ls @kky42/pi-flow --json`, and that `~/.local/bin/pi` actually
resolves into `@mariozechner/pi-coding-agent` rather than a same-named
bin from another package. It exercises `scripts/auth-import.sh` twice in
a row against the same throwaway volume with two distinct probe files
and asserts only the second remains (proving rotation replaces rather
than accumulates), that only the three expected auth-volume paths ever
appear mounted under `$HOME`, that `atelier-egress`'s entrypoint rejects
an IPv4-literal allow-list entry (e.g. the Podman gateway) with a clear
error, and that `--network=none` blocks both DNS and a raw-IP connection.
If `atelier-egress` is up it additionally asserts: `atelier-internal` has
no route out independent of the proxy; an allow-listed host succeeds; a
disallowed host gets a `403` from the proxy itself (not just "curl
failed") and the refusal is visible in `podman logs atelier-egress`; and
a hostname that merely *contains* an allow-listed name (`gist.github.com`,
which really resolves, rather than an unresolvable placeholder) is
refused the same way.

**A down `atelier-egress` FAILs the suite by default**, rather than
silently skipping the egress checks and still exiting 0 -- a clean pass
with zero egress coverage was the exact failure mode most worth catching.
Set `SMOKE_BASE_ONLY=1` to intentionally run only the base-image checks.

`just smoke-enter` (`tests/smoke-enter.sh`) covers `agent-enter.sh`
instead, and needs both `just build example` and a running `atelier-egress`
(`just egress-up`) first, since the default network profile is `proxied`.
**Refuses to run at all if a container named `agent-example` already
exists**, rather than destroying a live operator session -- this suite
creates and removes that container as part of testing it. The `agent-example`
overlay is used for the main coverage so `jq` (the overlay tool) must
actually be reachable; container-layer checks use `--no-tmux` (no TTY
needed), and tmux-layer checks use a private tmux socket
(`tmux -L atelier-test`, via `ATELIER_TMUX`) so it never touches the
operator's real tmux server or leaves its socket file behind.

It asserts the exact `podman inspect` flag set (`CapDrop`,
`NoNewPrivileges`, the `keep-id` uid mapping, `PidsLimit`, `--init`), that
mounts are exactly `/work` plus the three auth volumes and `/work` is the
requested `--dir`, the `proxied`/`none` network profiles (including the
proxy env vars), that a second invocation reuses the same container, that
a trailing command's exit code propagates (with and without `--`), the
staleness warning's presence/absence (built under a scratch overlay
directory and a scratch image tag -- `agent-example:latest` itself is
never mutated), that `--rebuild` produces a new container id, that a
stopped container is restarted rather than recreated
(`start_if_stopped`), and that a dead proxy name is reported without ever
touching the real `atelier-egress` (via `ATELIER_EGRESS_HOST` pointed at
a name that does not exist).

**Self-refusal is checked by filesystem identity, not by string**: via
this repository's alternate canonical path on this host, via a symlinked
parent, via a throwaway copy of just the two marker files (never this
repository's own tree, so nothing gets SELinux-relabelled by running the
suite), and via `--dir $HOME` (unconditional, no `--allow-self`). Every
`enter` call is captured for both exit code and output before anything is
asserted from it, so a broken state machine always produces a `FAIL` line
and the suite always reaches its summary -- an unguarded crash mid-run
used to abort with no summary and no `FAIL` at all.

Reuse-mismatch coverage: reattaching to an existing container with a
different `--dir`, or a different `--network` profile, is refused with
exit 4 rather than silently keeping the first directory or ignoring the
requested profile. tmux-layer coverage: a project name containing a `.`
round-trips through session creation and reuse (tmux parses a bare `.` in
a `-t` target as a separator, so this used to permanently break); the
second invocation against a live session is checked against the exact
headless outcome (no controlling terminal to actually attach to) and the
pane's own process is inspected to confirm it genuinely names the
`podman exec` into the right container, not just that a session by the
right name exists; and a container removed out from under a live tmux
session is recreated on the next invocation rather than silently attached
to a dead pane.

## Version pins

`claude` installs as a native binary (see below) and needs no runtime
beyond libc. `nodejs24` stays in the image anyway, because `codex` and
`pi` ship as npm packages whose `codex`/`pi` executables are Node shims
that `require()` the actual implementation at run time -- removing Node
after installing them would leave those two commands present on `PATH`
but non-functional.

`CLAUDE_VERSION=2.1.278` is a Containerfile `ARG`, bumpable (e.g. by
Renovate) without editing the build logic. `codex`/`pi`/`pi-flow` are
**not** `ARG`s -- `containers/agent-base/npm/package.json` and its
generated `package-lock.json` are the single source of truth for those
three versions and their entire transitive dependency graph, installed
with `npm ci --ignore-scripts` (not `npm install -g <pkg>@<version>`,
which pinned only the top-level version and left every transitive
dependency and its integrity metadata resolving from the live registry
at build time). To bump `codex`, `pi`, or `pi-flow`: edit
`npm/package.json` and regenerate `npm/package-lock.json`
(`npm install --package-lock-only --ignore-scripts`). `gh` and `git` are
also **not** pinned -- they ride whatever version the Fedora 44 base
digest ships; re-pin the base digest to change them.

`codex` and `pi` are installed to `~/.local/bin/` as symlinks constructed
from each package's own `bin` field, not from `node_modules/.bin/`:
`.bin/pi` resolves to `@earendil-works/pi-coding-agent`'s binary instead
of the pinned `@mariozechner/pi-coding-agent`'s, since both packages ship
a `pi` command and npm's hoisting picked the other one. Using `.bin/`
would have silently unpinned `pi`.

`pi-flow` (`@kky42/pi-flow`) has no `bin` entry and installs no
executable of its own -- it is a library `pi` loads, not a CLI you invoke
directly. `tests/smoke.sh` asserts its exact installed version via
`npm ls @kky42/pi-flow --json` run inside
`~/.local/lib/atelier-npm` (the project directory `npm ci` installed
into -- not `npm ls -g`, since none of these three packages install in
npm's global mode here).

Claude Code is installed by downloading the exact pinned version's
`linux-x64` binary directly from
`https://downloads.claude.ai/claude-code-releases/<version>/linux-x64/claude`
and verifying it against `CLAUDE_BINARY_SHA256` (a Containerfile `ARG`,
taken from that version's `manifest.json` and independently re-verified
against the downloaded artifact by hand before being pinned). This
replaced a vendored copy of Anthropic's own `install.sh`: that script's
first step always fetched whatever `https://downloads.claude.ai/claude-code-releases/latest`
currently returns -- a mutable endpoint -- and trusted a checksum from
that same mutable service, before ever looking at the requested version.
Pinning the script itself (an earlier fix) did not pin what the script
downloaded and ran. Only `linux-x64` is supported, since this image only
ever builds on the Fedora glibc/x86_64 base pinned at the top of the
Containerfile.
