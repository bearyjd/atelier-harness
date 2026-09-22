No CRITICAL findings. I found two HIGH and five MEDIUM/LOW issues.

- **HIGH** — `scripts/agent-enter.sh:140-148`  
  `--dir` is only canonicalized, not constrained to a safe project directory. Running from `$HOME` (the default is `$PWD`) or passing `--dir "$HOME"` mounts the entire home directory at `/work`; `--dir /` mounts the host root. This violates the no-`$HOME`-mount boundary and exposes SSH keys, host credentials, etc.  
  Fix: reject `$HOME`, `/`, and other non-project roots after `realpath`; ideally require an explicit project-root predicate or an opt-in override for exceptional paths.

- **HIGH** — `scripts/agent-enter.sh:239-246`  
  The auth-volume “empty?” probe runs `$IMAGE` on Podman’s default network without `--network=none`, `--userns=keep-id`, capability dropping, or `no-new-privileges`. It mounts each OAuth volume read-only, but an image with an accidental/malicious entrypoint or root user can execute with direct egress while a credential volume is attached.  
  Fix: avoid executing the selected overlay to inspect volume contents, or run a trusted fixed image with an explicit entrypoint and the hardened/no-network flags.

- **MEDIUM** — `scripts/agent-enter.sh:365-370`  
  An existing tmux session attaches before staleness or container-image-drift checks run. A session that survives after an overlay/base change silently bypasses the documented warning; it can also attach to a session whose container was stopped externally.  
  Fix: perform non-mutating staleness/drift checks before `attach_or_switch`; retain the no-auto-recreate behavior.

- **MEDIUM** — `scripts/agent-enter.sh:211-215`  
  A missing `org.atelier.source-sha` label is accepted without warning. Retagged, older, or manually built `agent-*:latest` images therefore look healthy.  
  Fix: treat an empty label as unverifiable/stale and print a warning with `<missing>`.

- **MEDIUM** — `scripts/agent-enter.sh:314-330`  
  Proxy preflight occurs only when creating a new container. After a reboot, a stopped persistent proxied container is restarted and entered even if `atelier-egress` is down, contrary to the documented fail-fast behavior.  
  Fix: run `check_network_preflight` before starting or reusing every proxied container, not only before `podman run`.

- **MEDIUM** — `tests/smoke-enter.sh:209-215`  
  The “fresh image has no staleness warning” test ignores `enter` failure via `|| true`. For example, with the container removed and egress down, entry fails before creation but emits no stale warning, so the assertion passes.  
  Fix: require `enter --no-tmux -- true` to succeed, then assert no warning and that the expected container is running.

- **LOW** — `tests/smoke-enter.sh:271-282`  
  The second-tmux-invocation assertion only counts existing sessions; it ignores whether the second invocation actually attached. A failed invocation can still leave the count at one and pass.  
  Fix: run under a controllable PTY/timeout and assert the expected attach/blocking outcome as well as the session count.

- **LOW** — `Justfile:193-195`, `README.md:280,325`  
  Documentation says `smoke-enter` only needs `just build example`, but its first default-proxied entry also requires a running `atelier-egress`.  
  Fix: document `just egress-up` as a prerequisite, or add an explicit preflight with that instruction.

Verified correct: build-time and entry-time overlay source-SHA calls use the same inputs and produced the same hash; `just build` safely shell-quotes and validates its project parameter; normal persistent-container creation includes the mandatory AUDIT §4.3 flags and exactly `/work` plus the three auth-volume mounts; the overlay convention and example image preserve the non-root/no-entrypoint model.