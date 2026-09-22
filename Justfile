# Atelier build/run recipes. See README.md for the full contract.
#
# `podman` is a shell alias to `distrobox-host-exec podman` inside the
# `dev` distrobox (AUDIT.md §4.4); aliases don't expand in `just` recipes,
# so route explicitly based on whether we're inside a container.
podman := if path_exists("/run/.containerenv") == "true" { "distrobox-host-exec podman" } else { "podman" }

base_digest := "registry.fedoraproject.org/fedora@sha256:dee2b968c71a167b08a6e0027db0380fc2f037796aeed620556a4fcbc6a1ed7f"
egress_network := "atelier-internal"
egress_container := "atelier-egress"
egress_port := "3128"

# Pinned so it never collides with any other podman network on this host:
# checked against `podman network inspect` on every existing network on
# 2026-09-22 (10.89.0.0/24 through 10.89.13.0/24 and 10.88.0.0/16 were all
# taken; 10.89.14.0/24 was free). containers/egress-proxy/tinyproxy.conf's
# `Allow` directive hardcodes this same value -- the two are not read from
# a shared source, so a change here requires the matching change there.
egress_subnet := "10.89.14.0/24"
# Public resolvers the egress proxy itself uses via --dns. See the comment
# in egress-up for why the network is created with --disable-dns (so
# these are the ONLY nameservers that ever reach the container's
# /etc/resolv.conf -- no race with an aardvark-dns entry, because there
# isn't one).
egress_dns_1 := "1.1.1.1"
egress_dns_2 := "9.9.9.9"
# Static IP for atelier-egress inside egress_subnet, stable across
# recreates. Required because --disable-dns means agent containers on
# atelier-internal cannot resolve the "atelier-egress" name by DNS
# anymore -- agent-enter.sh maps it via --add-host instead, reading this
# same IP from a running container at entry time (not a second copy of
# this constant; see the comment there). Must stay inside egress_subnet
# and outside whatever range netavark reserves for DHCP-style dynamic
# assignment on this subnet (.1 is the gateway; .10 is clear of it).
egress_ip := "10.89.14.10"

# Build agent-base:{latest,YYYYMMDD,g<sha>} from containers/agent-base.
build-base:
    #!/usr/bin/env bash
    # SOURCE_SHA is computed by scripts/source-sha.sh (a manifest hash: one
    # `sha256sum` line per input file, not concatenated bytes) so moving
    # content between files, or a change to the vendored installer,
    # changes the hash. It becomes the org.atelier.source-sha label that
    # agent-enter.sh (Phase 2) and egress-up (below) use for staleness
    # detection (AUDIT.md §3.1). Factored into one script so this recipe
    # and agent-enter.sh's own staleness check cannot compute it two
    # different ways and drift apart.
    #
    # g<sha> is AUDIT §3.2's one immutable tag -- Meute's dispatcher pins
    # to it specifically. It is only emitted when HEAD resolves to a real
    # commit AND the working tree is clean; a placeholder like "nogit"
    # would be silently identical across every build before the first
    # commit, which is mutable while looking immutable. Corrected
    # 2026-09-22 after critic review (C2) caught exactly that.
    set -euo pipefail
    cd "{{justfile_directory()}}"
    SOURCE_SHA="$(./scripts/source-sha.sh containers/agent-base)"
    DATE_TAG="$(date +%Y%m%d)"
    BUILD_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    TAG_ARGS=(-t "agent-base:latest" -t "agent-base:${DATE_TAG}")
    if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
        if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
            GIT_SHA="$(git rev-parse --short HEAD)"
            TAG_ARGS+=(-t "agent-base:g${GIT_SHA}")
            echo "Building agent-base (source-sha=${SOURCE_SHA:0:12}..., date=${DATE_TAG}, git=${GIT_SHA})"
        else
            echo "Building agent-base (source-sha=${SOURCE_SHA:0:12}..., date=${DATE_TAG}); omitting g<sha>: working tree has uncommitted changes"
        fi
    else
        echo "Building agent-base (source-sha=${SOURCE_SHA:0:12}..., date=${DATE_TAG}); omitting g<sha>: no commits yet"
    fi
    {{podman}} build \
        --build-arg "SOURCE_SHA=${SOURCE_SHA}" \
        --build-arg "BUILD_CREATED=${BUILD_CREATED}" \
        "${TAG_ARGS[@]}" \
        -f containers/agent-base/Containerfile \
        containers/agent-base

# Build atelier-egress:latest; allow-list is the union of the base list and every containers/<project>/allowlist.txt.
build-egress:
    #!/usr/bin/env bash
    # The effective allow-list is the UNION of the base list
    # (containers/egress-proxy/allowlist.txt) and every
    # containers/<project>/allowlist.txt in this repo -- there is one
    # shared proxy, not one per project, so a host any project's overlay
    # needs becomes reachable by every agent container on the proxied
    # network. See README.md "Overlay convention".
    #
    # SOURCE_SHA uses the same manifest-hash approach as build-base (via
    # scripts/source-sha.sh; see its comment). Inputs here are every file
    # the image bakes in AND that entrypoint.sh reads at container start
    # -- the base allow-list dir (source-sha.sh's own recursive walk) plus
    # every per-project allowlist.txt (passed as extra files), since a
    # change to ANY project's egress additions changes what this shared
    # proxy allows and must therefore change the image's staleness
    # fingerprint too.
    set -euo pipefail
    cd "{{justfile_directory()}}"

    # Stage the base allow-list plus every per-project allowlist.txt into
    # one directory, named by project, so entrypoint.sh's *.txt glob picks
    # up all of them at container start. Passed to `podman build` as a
    # named build context (allowlists=...) rather than copied into the
    # tracked containers/egress-proxy/ directory, so this generates no
    # stray files in the repo.
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    mkdir -p "$STAGE/allowlist.d"
    cp containers/egress-proxy/allowlist.txt "$STAGE/allowlist.d/00-base.txt"
    project_allowlists=()
    for f in containers/*/allowlist.txt; do
        [[ -e "$f" ]] || continue
        [[ "$f" == "containers/egress-proxy/allowlist.txt" ]] && continue
        project="$(basename "$(dirname "$f")")"
        cp "$f" "$STAGE/allowlist.d/${project}.txt"
        project_allowlists+=("$f")
    done

    SOURCE_SHA="$(./scripts/source-sha.sh containers/egress-proxy "${project_allowlists[@]}")"
    BUILD_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Building atelier-egress (source-sha=${SOURCE_SHA:0:12}..., allow-list union from: 00-base ${project_allowlists[*]:-<none>})"
    {{podman}} build \
        --build-context "allowlists=${STAGE}/allowlist.d" \
        --build-arg "SOURCE_SHA=${SOURCE_SHA}" \
        --build-arg "BUILD_CREATED=${BUILD_CREATED}" \
        -t "atelier-egress:latest" \
        -f containers/egress-proxy/Containerfile \
        containers/egress-proxy

# Build agent-<project>:{latest,YYYYMMDD,g<sha>} from containers/<project> (must FROM agent-base:latest).
build project:
    #!/usr/bin/env bash
    # See README.md "Overlay convention" for the containers/<project>/
    # layout this expects (Containerfile FROM agent-base:latest, optional
    # allowlist.txt consumed by build-egress).
    #
    # SECURITY (Codex review, .omc/reviews/phase1-codex.md): just
    # interpolates double-brace placeholders as raw text into this script
    # BEFORE bash ever parses it -- interpolating the bare "project"
    # parameter anywhere in the body is command injection (a project name
    # of z", echo INJECTED >&2, # -- quotes and comment marker included --
    # renders as executable shell) and a path-traversal vector via "../".
    # The quote() builtin shell-quotes the value at interpolation time, so
    # it's used exactly once below to capture it into the bash variable
    # $project; everything after that uses this bash variable (ordinary,
    # safe variable expansion), never the raw just parameter again. The
    # regex check is still required on top of quoting: quoting stops
    # injection, not a project name of "." or ".." resolving outside
    # containers/.
    set -euo pipefail
    cd "{{justfile_directory()}}"
    project={{quote(project)}}
    # Validation lives in scripts/valid-project-name.sh (code review M5) --
    # the sole source of truth, also called by agent-enter.sh, so the two
    # cannot drift apart the way they already had once.
    ./scripts/valid-project-name.sh "$project"
    overlay_dir="containers/${project}"
    if [[ ! -f "${overlay_dir}/Containerfile" ]]; then
        echo "build: no Containerfile at ${overlay_dir}/Containerfile" >&2
        exit 1
    fi
    if ! {{podman}} image exists agent-base:latest; then
        echo "build: agent-base:latest not found; run 'just build-base' first" >&2
        exit 1
    fi
    # Manifest includes every file under containers/agent-base/, not just
    # the overlay files (AUDIT.md §5): a base rebuild that changes what
    # agent-base:latest actually contains must also mark every overlay
    # image built on top of it as stale. Enumerated at call time (not a
    # hardcoded Containerfile+installer pair) so this stays correct
    # whatever agent-base's own file set happens to be -- it changed once
    # already (the vendored installer was replaced by a direct binary
    # download), and a hardcoded pair would have silently gone stale.
    mapfile -d '' -t base_files < <(find containers/agent-base -type f -print0)
    SOURCE_SHA="$(./scripts/source-sha.sh "${overlay_dir}" "${base_files[@]}")"
    DATE_TAG="$(date +%Y%m%d)"
    BUILD_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    TAG_ARGS=(-t "agent-${project}:latest" -t "agent-${project}:${DATE_TAG}")
    if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
        if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
            GIT_SHA="$(git rev-parse --short HEAD)"
            TAG_ARGS+=(-t "agent-${project}:g${GIT_SHA}")
            echo "Building agent-${project} (source-sha=${SOURCE_SHA:0:12}..., date=${DATE_TAG}, git=${GIT_SHA})"
        else
            echo "Building agent-${project} (source-sha=${SOURCE_SHA:0:12}..., date=${DATE_TAG}); omitting g<sha>: working tree has uncommitted changes"
        fi
    else
        echo "Building agent-${project} (source-sha=${SOURCE_SHA:0:12}..., date=${DATE_TAG}); omitting g<sha>: no commits yet"
    fi
    {{podman}} build \
        --build-arg "SOURCE_SHA=${SOURCE_SHA}" \
        --build-arg "BUILD_CREATED=${BUILD_CREATED}" \
        "${TAG_ARGS[@]}" \
        -f "${overlay_dir}/Containerfile" \
        "${overlay_dir}"

# Build every image this repo defines.
build-all: build-base build-egress

# Run the security-posture + toolchain smoke test against agent-base:latest.
smoke:
    "{{justfile_directory()}}/tests/smoke.sh"

# Run the agent-enter.sh state-machine smoke test (needs `just build example` and `just egress-up` first).
smoke-enter:
    "{{justfile_directory()}}/tests/smoke-enter.sh"

# Create/refresh the atelier-internal network and the egress proxy container.
egress-up: build-egress
    #!/usr/bin/env bash
    # Convergent, not just idempotent: recreates the network if its subnet
    # or DNS setting doesn't match, and recreates the container if its
    # org.atelier.source-sha doesn't match the image just built above --
    # otherwise editing allowlist.txt and running `just egress-up` would
    # rebuild the image, print success, and leave the OLD filter running
    # (critic H3 / security MEDIUM, both caught this).
    #
    # DETERMINISTIC DNS (Phase 2, 2026-09-2x -- replaces an earlier
    # 3-attempt recreate-on-failure loop). Root cause: atelier-egress
    # joins both the default `podman` network and {{egress_network}}
    # (--internal, so agent containers can reach it); Podman used to
    # order /etc/resolv.conf's nameservers non-deterministically across
    # separate `podman run` invocations with two --network flags --
    # sometimes {{egress_network}}'s aardvark-dns entry landed ahead of
    # the --dns entries below, and aardvark's authoritative NXDOMAIN for
    # public hostnames meant glibc never tried the real resolvers.
    # Reproduced on roughly 1 in 4 fresh starts across 10+ cycles, and
    # /etc/resolv.conf is mounted read-only even as root inside this
    # --read-only container (verified), so it cannot be patched after the
    # fact from inside -- the retry loop this replaced only worked around
    # the race by gambling on a fresh (re-randomized) resolv.conf each
    # attempt, and one report showed a "success" that still left DNS
    # broken 1 run in 10.
    #
    # The actual fix removes the race instead of retrying past it:
    # {{egress_network}} is created with --disable-dns, so aardvark-dns
    # never runs for it and never injects an entry into resolv.conf at
    # all -- only the --dns={{egress_dns_1}}/{{egress_dns_2}} flags below
    # ever reach it, deterministically. The cost: agent containers on
    # {{egress_network}} can no longer resolve the "atelier-egress" name
    # by DNS (nothing provides it anymore), so atelier-egress is given a
    # STABLE --ip ({{egress_ip}}) and agent-enter.sh's proxied profile
    # adds `--add-host atelier-egress:{{egress_ip}}`, reading that same
    # IP from the running container rather than hardcoding a second copy
    # of this constant. HTTPS_PROXY=http://atelier-egress:3128 is
    # unchanged -- only how that name resolves changed, from DNS to a
    # static /etc/hosts entry.
    set -euo pipefail

    # Waits up to ~10s for a container to report State.Running; on
    # timeout, prints its logs and returns non-zero rather than letting a
    # detached process that exited immediately look like success (Codex
    # review, .omc/reviews/phase1-codex.md).
    wait_for_running() {
        local name="$1"
        for _ in $(seq 1 20); do
            if {{podman}} inspect "$name" --format '{{{{.State.Running}}' 2>/dev/null | grep -q true; then
                return 0
            fi
            sleep 0.5
        done
        echo "{{egress_container}}: did not reach Running state within 10s" >&2
        {{podman}} logs "$name" >&2
        return 1
    }

    # Single post-start health check (no retry/recreate: with DNS now
    # deterministic, a failure here means something is actually wrong,
    # not an unlucky resolv.conf ordering -- retrying would just hide
    # that). Polls for a few seconds since the proxy may need a moment
    # after Running to actually service a connection.
    wait_for_dns() {
        local name="$1"
        for _ in $(seq 1 10); do
            {{podman}} exec "$name" getent hosts api.github.com >/dev/null 2>&1 && return 0
            sleep 1
        done
        echo "{{egress_container}}: cannot resolve api.github.com after starting" >&2
        {{podman}} logs "$name" >&2
        return 1
    }

    current_subnet="none"
    current_dns="none"
    if {{podman}} network exists {{egress_network}}; then
        current_subnet="$({{podman}} network inspect {{egress_network}} --format '{{{{range .Subnets}}{{{{.Subnet}}{{{{end}}')"
        current_dns="$({{podman}} network inspect {{egress_network}} --format '{{{{.DNSEnabled}}')"
    fi
    if [[ "$current_subnet" == "none" ]]; then
        echo "Creating internal network {{egress_network}} ({{egress_subnet}}, DNS disabled)"
        {{podman}} network create --internal --disable-dns --subnet {{egress_subnet}} {{egress_network}}
    elif [[ "$current_subnet" != "{{egress_subnet}}" || "$current_dns" != "false" ]]; then
        echo "Network {{egress_network}} is subnet=${current_subnet} dns-enabled=${current_dns}, expected subnet={{egress_subnet}} dns-enabled=false; recreating"
        if {{podman}} container exists {{egress_container}}; then
            {{podman}} rm -f {{egress_container}}
        fi
        {{podman}} network rm {{egress_network}}
        {{podman}} network create --internal --disable-dns --subnet {{egress_subnet}} {{egress_network}}
    else
        echo "Network {{egress_network}} already exists with the expected subnet and DNS disabled"
    fi

    built_sha="$({{podman}} image inspect atelier-egress:latest --format '{{{{index .Labels "org.atelier.source-sha"}}')"
    recreate=1
    if {{podman}} container exists {{egress_container}}; then
        running_sha="$({{podman}} inspect {{egress_container}} --format '{{{{index .Config.Labels "org.atelier.source-sha"}}')"
        echo "atelier-egress running source-sha:      ${running_sha}"
        echo "atelier-egress:latest built source-sha: ${built_sha}"
        if [[ "$running_sha" == "$built_sha" ]]; then
            echo "Container {{egress_container}} already matches the built image; leaving it running"
            {{podman}} start {{egress_container}} >/dev/null
            wait_for_running {{egress_container}}
            wait_for_dns {{egress_container}}
            recreate=0
        else
            echo "Config changed; recreating {{egress_container}}"
            {{podman}} rm -f {{egress_container}}
        fi
    fi

    if [[ "$recreate" -eq 1 ]]; then
        # --tmpfs mode=0700,uid=999,gid=999 was the original intent (a
        # tmpfs owned by and only accessible to the tinyproxy uid), but
        # Podman's --tmpfs does not accept uid=/gid= as mount options --
        # verified 2026-09-22, "Error: unknown mount option 'uid=999'"
        # from both --tmpfs and --mount type=tmpfs. 1777 (world-writable
        # + sticky, the same mode /tmp itself uses) is the fallback that
        # actually works: safe here specifically because this container
        # runs exactly one process (tinyproxy, uid 999, --cap-drop=ALL,
        # no-new-privileges), so "world-writable" means "writable by the
        # one uid that's ever running in here".
        # --ip only works with a single --network; with two, the target
        # network needs the extended `name:ip=addr` form (verified
        # 2026-09-2x -- a bare --ip alongside two --network flags is
        # refused: "can only be set for a single network").
        echo "Starting {{egress_container}}"
        {{podman}} run -d \
            --name {{egress_container}} \
            --restart=always \
            --network=podman \
            --network={{egress_network}}:ip={{egress_ip}} \
            --dns={{egress_dns_1}} \
            --dns={{egress_dns_2}} \
            --read-only \
            --tmpfs /run/tinyproxy:rw,mode=1777 \
            --cap-drop=ALL \
            --security-opt=no-new-privileges \
            atelier-egress:latest
        wait_for_running {{egress_container}}
        wait_for_dns {{egress_container}}
    fi
    {{podman}} ps --filter "name={{egress_container}}"

# Stop and remove the egress proxy container and its internal network.
egress-down:
    #!/usr/bin/env bash
    # No `|| true`: a network still in use, or a container that refuses
    # to stop, is a real failure and must surface as one -- not be
    # reported as "stopped and removed" regardless (security MEDIUM /
    # critic M6 both flagged the previous version doing exactly that).
    set -euo pipefail
    if {{podman}} container exists {{egress_container}}; then
        {{podman}} rm -f {{egress_container}}
        echo "removed container {{egress_container}}"
    else
        echo "container {{egress_container}} does not exist"
    fi
    if {{podman}} network exists {{egress_network}}; then
        {{podman}} network rm {{egress_network}}
        echo "removed network {{egress_network}}"
    else
        echo "network {{egress_network}} does not exist"
    fi

# Populate the three auth volumes from the owner's host credential files.
auth:
    #!/usr/bin/env bash
    # Named volumes, never a bind mount of $HOME (AUDIT.md §4.1):
    # bind-mounting ~/.claude carries history/projects/plugins/MCP
    # config, and bind-mounting just the credentials file breaks when a
    # CLI rotates its OAuth token by rename-over-write.
    #
    # The actual import (and the uid-1000-under-keep-id subtlety) is
    # factored into scripts/auth-import.sh so tests/smoke.sh can exercise
    # the identical code path against a throwaway file and volume,
    # without ever touching real credentials.
    set -euo pipefail
    cd "{{justfile_directory()}}"

    declare -A targets=(
        [atelier-auth-claude]="${HOME}/.claude/.credentials.json"
        [atelier-auth-codex]="${HOME}/.codex/auth.json"
        [atelier-auth-gh]="${HOME}/.config/gh/hosts.yml"
    )
    imported=0
    for volume in "${!targets[@]}"; do
        src="${targets[$volume]}"
        if [[ -f "$src" ]]; then
            ./scripts/auth-import.sh "$volume" "$src"
            imported=$((imported + 1))
        else
            echo "auth: SKIP ${volume} -- source not found: ${src}"
        fi
    done
    echo
    echo "auth: imported ${imported} of ${#targets[@]} credential files"
    if [[ "$imported" -eq 0 ]]; then
        echo "auth: FAILED -- no credential files were found to import" >&2
        exit 1
    fi
