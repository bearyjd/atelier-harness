No files modified.

## HIGH

- [containers/egress-proxy/tinyproxy.conf:56](/var/home/user/Documents/vibe-code/atelier-harness/containers/egress-proxy/tinyproxy.conf:56) — CONNECT filtering authorizes only the requested authority, then tunnels opaque TLS. An agent can CONNECT to an allow-listed shared-CDN endpoint and present SNI/Host for a different co-tenant on the same CDN IP. Tinyproxy cannot verify the ultimate TLS destination.  
  Fix: use an SNI-aware proxy that rejects absent/mismatched SNI (and ECH), or TLS interception; otherwise explicitly accept that CDN co-tenants are reachable.

- [containers/agent-base/Containerfile:60](/var/home/user/Documents/vibe-code/atelier-harness/containers/agent-base/Containerfile:60), [containers/egress-proxy/Containerfile:15](/var/home/user/Documents/vibe-code/atelier-harness/containers/egress-proxy/Containerfile:15) — The `FROM` digest is pinned, but every `dnf install` resolves mutable Fedora repository metadata. Rebuilding identical source can install changed root-build dependencies without changing `source-sha`.  
  Fix: consume a digest-pinned prepared base, or use an immutable RPM snapshot plus locked NEVRAs/hashes.

- [containers/agent-base/install-claude.sh:148](/var/home/user/Documents/vibe-code/atelier-harness/containers/agent-base/install-claude.sh:148) — The vendored script still fetches a mutable `latest` bootstrap binary; its manifest checksum comes from the same mutable service. `CLAUDE_VERSION` is only passed to that downloaded binary later. A changed release service can provide a malicious binary and matching checksum.  
  Fix: fetch an exact bootstrap release and verify its source-recorded hash/signature; ideally vendor the artifact.

- [Justfile:120](/var/home/user/Documents/vibe-code/atelier-harness/Justfile:120) — `{{project}}` is interpolated raw into Bash quotes. Verified with `just --dry-run build 'z"; echo INJECTED >&2; #'`, which renders executable host-shell commands; `../` also escapes `containers/`.  
  Fix: shell-quote before interpolation and enforce a canonical project-name allow-list before using it.

## MEDIUM

- [containers/agent-base/Containerfile:162](/var/home/user/Documents/vibe-code/atelier-harness/containers/agent-base/Containerfile:162) — `--ignore-scripts` blocks lifecycle hooks, but npm still resolves mutable transitive dependencies and integrity metadata from the live registry. Exact top-level versions do not lock the dependency graph.  
  Fix: commit a production `package.json`/lockfile and use `npm ci --ignore-scripts`; preferably fetch from a controlled, hash-verified cache.

- [containers/egress-proxy/tinyproxy.conf:69](/var/home/user/Documents/vibe-code/atelier-harness/containers/egress-proxy/tinyproxy.conf:69) — Filtering occurs before DNS resolution, using plaintext public resolvers and no resolved-IP policy. Resolver/on-path compromise or DNS rebinding of an allow-listed hostname can direct the proxy to private, loopback, or Podman-range addresses.  
  Fix: use authenticated validating DNS and reject private/link-local/loopback/Podman destination ranges after resolution.

- [containers/egress-proxy/entrypoint.sh:69](/var/home/user/Documents/vibe-code/atelier-harness/containers/egress-proxy/entrypoint.sh:69) — The “hostname” validator accepts IPv4 literals. A future overlay entry such as `10.88.0.1` would authorize access to the Podman gateway/host services for every agent.  
  Fix: enforce canonical DNS-name grammar and reject IP literals, local/reserved names, leading/trailing hyphens, and empty labels.

- [Justfile:243](/var/home/user/Documents/vibe-code/atelier-harness/Justfile:243), [tests/smoke.sh:403](/var/home/user/Documents/vibe-code/atelier-harness/tests/smoke.sh:403) — `egress-up` succeeds even if the detached proxy immediately exits; its final filtered `podman ps` also succeeds when empty. `just smoke` then skips all egress checks and exits zero.  
  Fix: wait for a running/healthy proxy and fail with logs; make normal smoke require proxy checks, with a separately named base-only smoke target.

## LOW

- [tests/smoke.sh:187](/var/home/user/Documents/vibe-code/atelier-harness/tests/smoke.sh:187) — Missing `gh`/`git` produces a nonempty “command not found” string, which the presence test treats as PASS.  
  Fix: capture and require exit status zero plus expected version-output grammar.

- [tests/smoke.sh:189](/var/home/user/Documents/vibe-code/atelier-harness/tests/smoke.sh:189) — `pi-flow` smoke coverage accepts any installed version, not pinned `3.1.3`.  
  Fix: inspect package metadata and assert the exact version.

- [tests/smoke.sh:82](/var/home/user/Documents/vibe-code/atelier-harness/tests/smoke.sh:82) — Zero `CapBnd` alone does not prove effective/permitted capabilities are empty.  
  Fix: assert `CapEff`, `CapPrm`, `CapBnd`, and ideally inheritable/ambient sets are zero.

- [tests/smoke.sh:265](/var/home/user/Documents/vibe-code/atelier-harness/tests/smoke.sh:265) — The auth test imports once only; it does not prove a re-import removes stale credentials as claimed.  
  Fix: import two distinct probes sequentially and assert only the second remains.

- [scripts/auth-import.sh:35](/var/home/user/Documents/vibe-code/atelier-harness/scripts/auth-import.sh:35) — `ATELIER_AUTH_IMAGE` can replace the image that receives the credential tar stream, with networking enabled. A malicious override image could read and exfiltrate it.  
  Fix: use a fixed trusted/digest-pinned extraction image with `--network=none`; reserve test overrides for an explicit test-only path.

Verified correct: base references are digest-pinned; installer-script hash matches its declared value; npm invocations consistently use `--ignore-scripts`; sudo removal is asserted; setuid stripping runs before switching to `agent`; the image defaults to uid/gid 1000; generated hostname filters are exact and escaped; HTTP/1.0 and forged `Host` headers do not redirect Tinyproxy’s parsed origin; proxy access is restricted to the configured internal subnet with no published host port; and the fixed `$HOME`, raw-IP, and `keep-id` auth-import checks are substantive.

The OAuth refresh-token race remains a documented, known Phase 2 carry-forward from `AUDIT.md`, not a newly discovered finding.