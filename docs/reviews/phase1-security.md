# Atelier Phase 1 — Security Review

**Date:** 2026-09-21
**Scope:** `containers/agent-base/Containerfile`, `containers/egress-proxy/*`, `tests/smoke.sh`, `Justfile`, `README.md`, `.gitignore`, against `AUDIT.md` §4.1–4.3 and §6.
**Method:** Read every file, then tested the built `agent-base:latest` image and the running `atelier-egress` proxy on `atelier-internal` empirically. All `podman` invocations were `distrobox-host-exec podman`.

**Tree changes:** none. No file in the repository was modified. I created and removed three throwaway podman volumes named `atelier-sectest-auth`, `atelier-sectest-tmp` and `atelier-sectest-fix`. No other host state changed.

---

## Verdict

One blocking finding. Under the exact AUDIT §4.3 flag set, no agent container can read the credentials that `just auth` writes, so Phase 1 is not complete as reported.

The egress network isolation itself is sound. I could not find a way for an agent container on `atelier-internal` to reach any host off the allow-list, reach another podman bridge, or tunnel out over DNS. The weaknesses are in the proxy's handling of non-CONNECT requests, in who may use the proxy, in the smoke test's ability to detect a regression, and in several "verified" comments that are factually wrong.

**Counts by severity:** 1 blocking HIGH, 3 further HIGH, 7 MEDIUM, 4 LOW, 1 NOTE.

---

## BLOCKING

### HIGH — `just auth` writes credentials the agent user cannot read

**Where:** `Justfile:109-127`

`podman volume import` writes the extracted file under a different user-namespace mapping than `--userns=keep-id:uid=1000,gid=1000` uses at run time. The file arrives mode 0600 owned by container uid 999, not 1000. Every CLI in every agent container fails to authenticate.

Observed, replicated into a throwaway volume with a dummy credential file:

```
$ podman run --rm --userns=keep-id:uid=1000,gid=1000 --cap-drop=ALL \
    --security-opt=no-new-privileges -v atelier-sectest-auth:/home/agent/.claude \
    agent-base:latest bash -c 'id; cat /home/agent/.claude/.credentials.json'
uid=1000(agent) gid=1000(agent) groups=1000(agent)
cat: /home/agent/.claude/.credentials.json: Permission denied
READ_DENIED
```

The same volume read from a container **without** `keep-id` succeeds, which is why this was missed:

```
$ podman run --rm -v atelier-sectest-auth:/home/agent/.claude agent-base:latest \
    bash -c 'id -u; cat /home/agent/.claude/.credentials.json'
1000
{"fake":"token"}READ_OK
```

Inside a `keep-id` container the file reports as owner 999, which `stat` renders as `UNKNOWN:UNKNOWN`:

```
600 UNKNOWN:UNKNOWN /home/agent/.claude/.credentials.json
```

**Why this is dangerous beyond being broken:** the obvious workarounds all weaken the posture. Loosening the file to 0644 exposes the OAuth token to any other uid in the container. Dropping `keep-id` breaks the AUDIT §4.3 bind-mount model. Chowning from a privileged helper container reintroduces a root-capable step into the auth path.

**Fix, verified working.** Pipe the tar into a container running the same flag set rather than into `volume import`:

```sh
import_one() {
    local volume="$1" src="$2"
    [[ -f "$src" ]] || { echo "auth: skipping ${volume} -- not found: ${src}" >&2; return 0; }
    {{podman}} volume create "$volume" >/dev/null 2>&1 || true
    tar -cf - -C "$(dirname "$src")" "$(basename "$src")" \
      | {{podman}} run --rm -i \
          --userns=keep-id:uid=1000,gid=1000 \
          --cap-drop=ALL --security-opt=no-new-privileges \
          -v "$volume":/dest agent-base:latest tar -xf - -C /dest
}
```

Proof this produces a readable credential under the Phase 2 flags:

```
600 1000:1000 /home/agent/.claude/.credentials.json
{"fake":"tok"} READ_OK
```

**Related, lower priority:** `podman volume import` is additive, not replacing. A second import into the same volume leaves earlier files in place. Verified by importing `other.json` into a volume that already held `.credentials.json`; both survived. A rotated token therefore leaves the stale file behind unless the recipe clears the volume first.

---

## HIGH

### HIGH — the proxy is neither CONNECT-only nor port-443-only

**Where:** `containers/egress-proxy/tinyproxy.conf:23`, claim repeated at `tinyproxy.conf:1-4`, `tinyproxy.conf:21-22` and `README.md:57-58`

`ConnectPort 443` constrains the CONNECT method only. Tinyproxy still services ordinary forward-proxy requests, and those reach **any TCP port** on any allow-listed host. The allow-list still applies to the hostname, so this does not widen *which* hosts are reachable, but it breaks the stated invariant that the proxy is a CONNECT-only HTTPS path.

Strongest proof, from an agent container on `atelier-internal`. The proxy opened a TCP session to a non-web port on an allow-listed host and relayed bytes:

```
$ curl -sS -x http://atelier-egress:3128 --max-time 12 http://github.com:22/
curl: (52) Empty reply from server
```

Cleartext HTTP reaching a credential-bearing allow-listed origin:

```
$ curl -sS -x http://atelier-egress:3128 -o /dev/null -w '%{http_code}\n' http://api.anthropic.com/
400
```

An arbitrary high port is dialed rather than refused, which is why it hangs instead of returning 403:

```
$ curl -sS -x http://atelier-egress:3128 --max-time 12 http://github.com:8080/
curl: (28) Operation timed out after 12002 milliseconds with 0 bytes received
$ curl -sS -x http://atelier-egress:3128 --max-time 12 http://github.com:9418/
curl: (28) Operation timed out after 12002 milliseconds with 0 bytes received
```

The allow-list does still hold on the plain-HTTP path. A non-listed host is refused with a real 403 from the proxy, not a network error:

```
$ curl -sS -x http://atelier-egress:3128 -o /dev/null -w '%{http_code}\n' http://example.com/
403
```

**Fix.** Tinyproxy has no directive to refuse non-CONNECT methods, so there are two honest options. Either accept the behaviour and correct the comments at `tinyproxy.conf:1-4` and `README.md:57-58` so the documented invariant matches reality, or move to a proxy that can gate on method, for example Squid with `http_access deny !CONNECT` plus `SSL_ports`. If the design intent in AUDIT §4.2 is genuinely "CONNECT-only, no cleartext", the config does not currently implement it.

### HIGH — `tests/smoke.sh` asserts `$HOME` is not a mount point using a field that can never match

**Where:** `tests/smoke.sh:90`, consumed at `tests/smoke.sh:139-143`

```bash
echo "HOME_MOUNT=$(awk -v h="$HOME" "\$2==h{print \$2}" /proc/self/mountinfo | head -1)"
```

Field 2 of `/proc/self/mountinfo` is the parent mount ID, a number. It is never a path, so it never equals `/home/agent`. The check "`$HOME` is not a separate mount point" passes unconditionally. This is the assertion guarding the no-`$HOME`-mounts rule from AUDIT §4.1, the core credential-isolation control.

Proof. Field 2 finds nothing and field 5 finds nothing in a clean container, but when a volume really is mounted over `/home/agent`, only field 5 catches it:

```
-- field2 test (what smoke.sh does) --
(empty above = check is vacuous)
-- field5 test (correct) --
(empty)

=== simulate a $HOME volume mount ===
F5MATCH
done
```

`F2MATCH` never printed. A real `$HOME` mount is invisible to the current assertion.

**Fix.** Use field 5, the mount point:

```bash
echo "HOME_MOUNT=$(awk -v h="$HOME" "\$5==h{print \$5}" /proc/self/mountinfo | head -1)"
```

### HIGH — the smoke test's proxy negative assertions pass on any failure

**Where:** `tests/smoke.sh:222-235` producing the checks at `tests/smoke.sh:245-255`

Both negative checks derive from curl's exit status:

```bash
if curl -sS --max-time 10 --proxy "$HTTPS_PROXY" https://example.com >/dev/null 2>&1; then
  echo "EXAMPLE_ALLOWED=1"
else
  echo "EXAMPLE_ALLOWED=0"
fi
```

Any failure sets `0` and the check passes: DNS failure, proxy unreachable, connection reset, timeout. If the filter file were empty, if the proxy were reachable but broken, or if the test container simply could not route to the proxy, both checks would still report PASS. Only the first check, the positive one against `api.github.com`, would fail.

The anchoring check compounds this. It targets `github.com.attacker.invalid`. `.invalid` is an IANA-reserved TLD that can never resolve, so the assertion cannot distinguish "the anchored filter refused it" from "the hostname does not exist". It would pass identically against an unanchored filter.

The filter genuinely is anchored, which I confirmed independently from the proxy's own logs rather than from the test:

```
CONNECT  Request (file descriptor 4): CONNECT github.com.attacker.invalid:443 HTTP/1.1
NOTICE   Proxying refused on filtered domain "github.com.attacker.invalid"
```

**Fix.** Assert the proxy's status code rather than curl's exit status, so the reason for refusal is checked:

```bash
code=$(curl -sS --max-time 10 --proxy "$HTTPS_PROXY" -o /dev/null -w '%{http_code}' \
         http://example.com/ || echo 000)
[[ "$code" == "403" ]] || fail "..."
```

For the CONNECT path, curl exits 56 with "CONNECT tunnel failed, response 403"; assert on that string or use the plain-HTTP form above, which returns a clean 403 body. Also replace the `.invalid` target with a resolvable name that only substring-matches an allow-listed host.

---

## MEDIUM

### MEDIUM — `just egress-up` never applies a configuration change

**Where:** `Justfile:60-89`, specifically `Justfile:69-72`

```
if {{podman}} container exists {{egress_container}} 2>/dev/null; then
    echo "Container {{egress_container}} already exists; leaving it running"
    {{podman}} start {{egress_container}} >/dev/null 2>&1 || true
```

The recipe depends on `build-egress`, so the image is rebuilt with the new `allowlist.txt` baked in, and then the stale container is left running with the old filter. The operator sees a successful build and a running container and concludes the change took effect.

**Failure scenario:** someone removes `chatgpt.com` from `allowlist.txt` to cut off an unwanted egress path, runs `just egress-up`, sees success, and the host remains reachable indefinitely. This is the realistic failure path for the entire egress control, because tightening the allow-list is the routine operation.

**Fix.** Compare the running container's image against the freshly built one and recreate on mismatch:

```sh
running_sha=$({{podman}} inspect {{egress_container}} \
  --format '{{{{index .Config.Labels "org.atelier.source-sha"}}}}' 2>/dev/null || echo none)
if [[ "$running_sha" != "$SOURCE_SHA" ]]; then
    echo "egress config changed; recreating {{egress_container}}"
    {{podman}} rm -f {{egress_container}} >/dev/null 2>&1 || true
    # ... fall through to the create path
fi
```

At minimum, print a loud warning rather than the current reassuring message.

### MEDIUM — the proxy accepts clients from every podman network, not just `atelier-internal`

**Where:** `containers/egress-proxy/tinyproxy.conf:15-19`

```
Allow 10.0.0.0/8
Allow 172.16.0.0/12
Allow 192.168.0.0/16
```

This permits all of RFC1918. `atelier-internal` is `10.89.13.0/24` and the default bridge is `10.88.0.0/16`, so every container this user runs on any non-internal network can use the proxy. Verified from the default bridge and from an unrelated network:

```
### reach proxy from DEFAULT podman network (10.88.0.7:3128)
code=200
### reach proxy from an UNRELATED network (sidecar)
code=200
```

**Scope of the impact, stated honestly.** Containers on those networks already have unrestricted internet access, so they gain nothing today. Agent containers are unaffected, because `atelier-internal` has no default route and cannot reach the proxy's other interface at all:

```
$ # from atelier-internal, to the proxy's address on the default bridge
bash: connect: Network is unreachable
```

The finding is least-privilege and defence-in-depth: the allow-list boundary is not scoped to Atelier, so any future workload placed on an internal network beside a proxy-reachable one inherits egress the operator never granted.

**Fix.** Narrowing `Allow` alone is insufficient, because `10.89.13.0/24` was dynamically assigned and changes whenever the network is recreated. Pin the subnet and the allow rule together:

```
# Justfile
{{podman}} network create --internal --subnet 10.89.13.0/24 {{egress_network}}

# tinyproxy.conf, replacing the three RFC1918 lines
Allow 10.89.13.0/24
```

### MEDIUM — a Containerfile comment marked "verified empirically" is false

**Where:** `containers/agent-base/Containerfile:51-60`

The comment claims removing sudo "cascades out sudo's own dependencies (pam, authselect, libpwquality, cracklib, ...), none of which git/gh/node/npm or `useradd`/`groupadd` below need -- verified empirically."

None of those packages were removed:

```
$ podman run --rm agent-base:latest rpm -qa | grep -Ei 'pam|authselect|sudo|shadow|cracklib|libpwquality'
pam-libs-1.7.2-2.fc44.x86_64
cracklib-2.10.3-1.fc44.x86_64
libpwquality-1.4.5-15.fc44.x86_64
pam-1.7.2-2.fc44.x86_64
authselect-libs-1.7.1-1.fc44.x86_64
shadow-utils-4.19.0-7.fc44.x86_64
authselect-1.7.1-1.fc44.x86_64
```

The sudo removal itself did work:

```
$ podman run --rm agent-base:latest sh -c 'command -v sudo || echo NO_SUDO'
NO_SUDO
```

Eleven setuid-root binaries remain in the image:

```
$ podman run --rm agent-base:latest find / -perm -4000 -type f 2>/dev/null
/usr/bin/chage
/usr/bin/chfn
/usr/bin/chsh
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/newgrp
/usr/bin/pam_timestamp_check
/usr/bin/passwd
/usr/bin/su
/usr/bin/umount
/usr/bin/unix_chkpwd
```

At run time `no-new-privileges` neuters them, which I confirmed:

```
uid=1000(agent) gid=1000(agent) groups=1000(agent)
NoNewPrivs:	1
```

So this is not an escalation path under the documented flags. It matters for two reasons. The image ships an attack surface the comment asserts is gone, and the review model for this repo depends on comments marked "verified" being true. A reviewer who trusts this line skips the check.

**Fix.** Correct the comment to say only sudo was removed, and strip the setuid bits explicitly:

```dockerfile
RUN for f in /usr/bin/chage /usr/bin/chfn /usr/bin/chsh /usr/bin/gpasswd \
             /usr/bin/mount /usr/bin/newgrp /usr/bin/pam_timestamp_check \
             /usr/bin/passwd /usr/bin/su /usr/bin/umount /usr/bin/unix_chkpwd; do \
        [ -e "$f" ] && chmod u-s "$f"; \
    done; true
```

Then add a smoke assertion that `find / -perm -4000 -type f` returns nothing.

### MEDIUM — the Claude installer is refetched unpinned at every build

**Where:** `containers/agent-base/Containerfile:112`

```dockerfile
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}"
```

I read the installer. It is better than the `curl | bash` shape suggests:

- It validates the version argument against a strict regex, `^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?)$`, so the build arg cannot inject shell.
- It fetches a manifest and extracts a SHA-256 per platform, at `install.sh:85-96` and `:158-171`.
- It validates the checksum format is exactly 64 hex characters before use.
- It verifies the downloaded binary and aborts on mismatch with "Checksum verification failed" at `install.sh:214-215`.
- Downloads come from `https://downloads.claude.ai/claude-code-releases`.

So the binary is checksum-verified. The residual issue is that the **script** is unpinned and fetched fresh on every build. Two builds of an identical Containerfile can execute different installer logic. That breaks the AUDIT §3.1 contract, where `org.atelier.source-sha` is supposed to imply image content for staleness detection.

**Fix.** Vendor the installer into `containers/agent-base/install-claude.sh`, verify its own sha256 in the build, and `COPY` it. Include it in the `SOURCE_SHA` computation in `Justfile:21` so a change to the installer is visible to the staleness check.

### MEDIUM — `gh` and `git` are unpinned but the smoke test asserts exact versions

**Where:** `containers/agent-base/Containerfile:37-38` versus `tests/smoke.sh:34-35` and `:187-188`

The Containerfile installs them with no version constraint:

```
37	      git-core \
38	      gh \
```

The smoke test hardcodes what Fedora happened to ship:

```
34	GH_VERSION="2.97.0"
35	GIT_VERSION="2.55.0"
```

Currently consistent:

```
$ podman run --rm agent-base:latest sh -c 'rpm -q gh git-core'
gh-2.97.0-2.fc44.x86_64
git-core-2.55.0-1.fc44.x86_64
```

The next Fedora package refresh breaks the suite while the failure message claims a "pinned version" was violated. Either pin the dnf packages with `gh-2.97.0*` and `git-core-2.55.0*` so the assertion is true, or drop these two from the pin checks and assert only that the binaries exist and run.

### MEDIUM — `.omc/` is not ignored and would be committed

**Where:** `.gitignore`

The repository has no commits yet and `.omc/` is untracked but not ignored:

```
$ git check-ignore -v .omc/state/hud-stdin-cache.json
NOT IGNORED

$ git add -An | grep -i omc
add '.omc/project-memory.json'
add '.omc/sessions/01a0c664-0a2f-7850-b8b3-8b8f144b2266.json'
add '.omc/state/.state-mutation-locks.db'
add '.omc/state/agent-replay-b1842e0d-fd5f-4f0b-bf14-a74711a6493e.jsonl'
add '.omc/state/hud-stdin-cache.json'
```

Contents today are agent-orchestration telemetry of low sensitivity, for example:

```json
{"t":0,"agent":"aphase1","agent_type":"phase1-critic","event":"agent_start","parent_mode":"none"}
```

These files capture session and tool activity, include a sqlite lock database, and will grow. They should not enter history.

**Fix.** Add to `.gitignore` before the first commit:

```
# Agent orchestration state
/.omc/
```

If any part of `.omc/` is intended to be shared, ignore `/.omc/state/` and `/.omc/sessions/` specifically and keep `project-memory.json`.

### MEDIUM — this repository sits inside its own trust boundary

**Where:** `README.md:23-31`

The README argues that per-project overlays live in Atelier rather than in each project's repo, so an agent cannot edit the definition of its own sandbox. That reasoning holds for every repository except this one.

An interactive agent container entered with `/work` bound to `atelier-harness` can write:

- `containers/egress-proxy/resolv.conf`, redirecting the proxy's own DNS to an attacker-controlled resolver so that allow-listed names resolve to attacker IPs on the next `egress-up`.
- `containers/egress-proxy/allowlist.txt`, adding any host.
- `Justfile`, changing the run flags for every future container.

None of these take effect immediately, but all take effect the next time the owner runs a build or `egress-up`, which is exactly the trusted moment.

**Fix.** State the exception in the README, and treat Atelier as a repo that is never opened inside an Atelier agent container. If it must be, mount it read-only. A Phase 2 guard in `agent-enter.sh` that refuses to bind Atelier's own directory as `/work` without an explicit override flag is the cheap enforcement.

---

## LOW

### LOW — `HTTP_PROXY` is exported uppercase only

**Where:** `containers/agent-base/Containerfile:87-89`

Curl deliberately ignores uppercase `HTTP_PROXY` as an httpoxy mitigation, honouring only lowercase `http_proxy`. Uppercase `HTTPS_PROXY` is honoured. Observed from a proxied container with both uppercase variables set: the HTTPS request traversed the proxy, and the plain-HTTP request never reached it.

```
### allow-listed host 443 (api.github.com)
code=200
### allow-listed host PLAIN HTTP port 80 (http://github.com)
curl: (6) Could not resolve host: github.com
```

This fails closed on `atelier-internal`, so it is not a vulnerability. It does mean the proxied profile silently cannot do plain HTTP through curl, and any tool that reads lowercase `http_proxy` or `https_proxy`, which includes much of the Python and Go ecosystem, gets no proxy at all.

**Fix.** Declare and inject both cases:

```dockerfile
ENV HTTP_PROXY="" HTTPS_PROXY="" NO_PROXY="" \
    http_proxy="" https_proxy="" no_proxy=""
```

### LOW — the allow-list filter lives in a world-writable directory

**Where:** `containers/egress-proxy/tinyproxy.conf:35`, `containers/egress-proxy/entrypoint.sh:14`

```
$ podman exec atelier-egress stat -c "%a %U:%G %n" /tmp /tmp/tinyproxy /tmp/tinyproxy/filter
1777 root:root /tmp
755 tinyproxy:tinyproxy /tmp/tinyproxy
644 tinyproxy:tinyproxy /tmp/tinyproxy/filter
```

The file that *is* the security control sits under a mode-1777 directory on a writable rootfs. Only the tinyproxy uid runs in this container today, so it is not currently exploitable, and the sticky bit protects the existing path. It is still the wrong home for the control.

**Fix.** Write the filter to a dedicated directory created at build time, mode 0700, owned by tinyproxy, and harden the container:

```
--read-only --tmpfs /run/tinyproxy:rw,mode=0700,uid=999,gid=999
```

with `Filter "/run/tinyproxy/filter"` and a matching `FILTER_FILE` default in `entrypoint.sh`.

### LOW — the `:z` mount relabels a file inside the repository

**Where:** `Justfile:84`

```
--volume "{{justfile_directory()}}/containers/egress-proxy/resolv.conf:/etc/resolv.conf:z,ro"
```

`:z` is the shared label. It has already relabelled a tracked source file, and the label carries no MCS category, so any container on this host can read it:

```
$ ls -Z containers/egress-proxy/resolv.conf containers/egress-proxy/allowlist.txt
system_u:object_r:container_file_t:s0        containers/egress-proxy/resolv.conf
unconfined_u:object_r:user_home_t:s0         containers/egress-proxy/allowlist.txt
```

The content is two public nameserver addresses, so disclosure is immaterial. The forward-looking problem is a label conflict: AUDIT §4.3 mounts the project directory as `:Z`, a private relabel. If anyone ever opens `atelier-harness` as a project, the `:Z` relabel assigns a private MCS category to the whole tree including this file, and the running egress container, which holds a different category, loses read access on its next restart.

**Fix.** Copy `resolv.conf` into the image at build time, or generate it in `entrypoint.sh`, and drop the bind mount. That removes the relabel entirely and makes the DNS configuration part of the image's `source-sha`.

### LOW — dead code in the smoke test

**Where:** `tests/smoke.sh:45-54`

The `check()` helper is defined and never called. Every assertion is written out longhand instead. Remove it, or use it, so a future reader does not assume checks route through it.

---

## NOTE

### NOTE — no shell-injection surface in the Justfile

Reviewed specifically because it was asked. There is none.

- No recipe takes a parameter, so no user-controlled value is interpolated into any recipe body.
- `{{justfile_directory()}}` is quoted at every use: `Justfile:20`, `:39`, `:55` and `:84`.
- `{{podman}}` is intentionally unquoted so `distrobox-host-exec podman` word-splits into two arguments. That is correct and necessary.
- The `auth` recipe's `import_one` quotes `"$volume"`, `"$src"`, `"$(dirname "$src")"` and `"$(basename "$src")"` correctly.

Two minor notes. `Justfile:55` is a non-shebang recipe, so `{{justfile_directory()}}/tests/smoke.sh` is unquoted and would break on a path containing spaces. This is a robustness issue, not an injection one, since `just` interpolates a literal path and not shell metacharacters. And `--restart=always` at `Justfile:81` means the proxy returns after a reboot even if the operator tore down everything else; arguably desirable, worth knowing.

**On the specific question of what `auth` leaves behind:** nothing. The tar is streamed through a pipe, so no archive is written to `/tmp`, and nothing enters a container image layer. Credentials go only into the named volumes. That part of the design is correct.

**On re-runnability:** `build-base` and `build-egress` are safe to re-run. `egress-up` is safe to re-run but does not apply changes, per the MEDIUM finding above. `auth` is safe to re-run but is additive rather than replacing.

---

## Verified correct

### Egress isolation

All tests run from an agent container on `atelier-internal`, that is `podman run --rm --network=atelier-internal ... agent-base:latest`.

| Test | Result | Evidence |
|---|---|---|
| CONNECT to non-listed host on 443 | refused | `curl: (56) CONNECT tunnel failed, response 403` |
| CONNECT to allow-listed host on 443 | allowed | `code=200` for `https://api.github.com` |
| CONNECT to allow-listed host on 8443 | refused | `curl: (56) CONNECT tunnel failed, response 403` |
| CONNECT to a bare IP literal | refused | `curl: (56) CONNECT tunnel failed, response 403` |
| CONNECT to `github.com.` trailing dot | refused, fails closed | `curl: (56) CONNECT tunnel failed, response 403` |
| Plain HTTP to non-listed host | refused by proxy | `code=403` for `http://example.com/` |
| Direct HTTPS with no proxy variables | blocked at DNS | `curl: (6) Could not resolve host: api.github.com` |
| Direct to a public IP with no proxy | no route | `curl: (7) Failed to connect to 140.82.121.4 port 443` |
| DNS for a public name on the internal net | NXDOMAIN, no tunnel | `getent hosts api.github.com` returned NXDOMAIN |
| DNS for the proxy's own name | resolves | `10.89.13.2  atelier-egress.dns.podman` |
| Reaching another podman bridge | unreachable | `bash: connect: Network is unreachable` |
| Proxy port published to host | not published | `podman port atelier-egress` returned nothing |

**One result that looks wrong and is not.** Uppercase `GITHUB.COM` returns 200. Tinyproxy's filter matching is case-insensitive by default and DNS is case-insensitive, so this resolves to the same allow-listed host. This is correct behaviour, not a bypass.

### Generated filter is correctly anchored and escaped

```
$ podman exec atelier-egress cat /tmp/tinyproxy/filter
^api\.anthropic\.com$
^statsig\.anthropic\.com$
^api\.openai\.com$
^chatgpt\.com$
^auth\.openai\.com$
^github\.com$
^api\.github\.com$
^objects\.githubusercontent\.com$
^codeload\.github\.com$
```

Every entry from `allowlist.txt` is present, dots are escaped so they cannot match an arbitrary character, and both anchors are applied. `entrypoint.sh` fails loudly if the directory is missing or contains no `*.txt` file, which is the right default.

### Proxy logs both allows and refusals

`LogLevel Info` surfaces the refusal reason, which makes the control auditable:

```
CONNECT  Request (file descriptor 4): CONNECT gist.github.com:443 HTTP/1.1
NOTICE   Proxying refused on filtered domain "gist.github.com"
CONNECT  Request (file descriptor 4): CONNECT raw.githubusercontent.com:443 HTTP/1.1
NOTICE   Proxying refused on filtered domain "raw.githubusercontent.com"
```

Note that `raw.githubusercontent.com` and `gist.github.com` are correctly **not** on the base list, so the anchoring is doing real work against near-miss GitHub hostnames.

### Container hardening

Egress proxy:

```
$ podman inspect atelier-egress --format '...'
ReadOnly=false Pids=2048 CapAdd=[] CapDrop=[CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER
CAP_FSETID CAP_KILL CAP_NET_BIND_SERVICE CAP_SETFCAP CAP_SETGID CAP_SETPCAP
CAP_SETUID CAP_SYS_CHROOT] SecurityOpt=[no-new-privileges] Restart=always

$ podman exec atelier-egress id
uid=999(tinyproxy) gid=999(tinyproxy) groups=999(tinyproxy)
```

Non-root, empty effective capability set, `no-new-privileges` on. Only `--read-only` is missing, covered in the LOW findings.

Agent base, under the AUDIT §4.3 flag set:

```
uid=1000(agent) gid=1000(agent) groups=1000(agent)
NoNewPrivs:	1
```

```
$ podman run --rm agent-base:latest sh -c 'ls -ld /work /home/agent /home/agent/.local ...'
drwx------. 6 agent agent 20 /home/agent
drwxr-xr-x. 6 agent agent  6 /home/agent/.local
drwxr-xr-x. 2 agent agent 14 /home/agent/.local/bin
-rw-------. 1 agent agent 26 /home/agent/.npmrc
drwxr-xr-x. 2 agent agent 24 /work
prefix=/home/agent/.local
```

`/home/agent` is 0700, `/work` and the npm prefix are owned by the agent user, and `.npmrc` is 0600. The npm prefix redirect to `/home/agent/.local` is correct and lands binaries on the `PATH` set at `Containerfile:73`. Smoke test confirms `CapBnd` is all zeros and no host dotfiles exist under `/home/agent`.

### Supply chain

- Both Containerfiles pin the identical base image by digest: `registry.fedoraproject.org/fedora@sha256:dee2b968c71a167b08a6e0027db0380fc2f037796aeed620556a4fcbc6a1ed7f`, at `agent-base/Containerfile:10` and `egress-proxy/Containerfile:6`.
- All three npm installs use `--ignore-scripts`, at `agent-base/Containerfile:118-122`. No third-party postinstall code runs.
- The Claude installer verifies a SHA-256 for the downloaded binary and aborts on mismatch. See the MEDIUM finding for the residual unpinned-script issue.
- dnf caches are removed in the same layer as the install, at `Containerfile:48-49` and `:59-60`, so nothing is recoverable from an intermediate layer.
- `--setopt=install_weak_deps=False` keeps the package set minimal.

---

## Recommended order of work

1. Fix `just auth` with the verified `podman run -i --userns=keep-id` approach. This unblocks Phase 2.
2. Fix the three smoke-test assertions, `tests/smoke.sh:90`, `:222` and `:231`, so the suite can actually detect a regression. Without this the remaining fixes cannot be verified.
3. Decide on the plain-HTTP relay. Either document the real behaviour or move to a proxy that can gate on method.
4. Make `just egress-up` recreate on config change.
5. Correct the false comment at `agent-base/Containerfile:51-57` and strip setuid bits.
6. Add `/.omc/` to `.gitignore` before the first commit.
7. The remaining MEDIUM and LOW items.
