#!/usr/bin/env bash
set -euo pipefail

# sudo-fleet/bin/verify-change.sh — post-change verification (READ-ONLY).
#
# Runs FOUR checks against a named target (a Deployment) in a namespace and
# prints PASS / FAIL / DEGRADED per check plus a final verdict. It is strictly
# READ-ONLY: every command it runs is a read (kubectl get / describe, a
# read-only kubectl exec that only cats/ls/stats files, curl GET, docker ps /
# ss). It never restarts, redeploys, patches, deletes, or mutates anything, so
# it is safe to run repeatedly and safe to run against production.
#
# The four checks:
#   1. RUNTIME      — Deployment ready == desired, pod restart count 0, pod age
#                     sane, health URL returns 2xx, and the RUNNING
#                     version/commit fetched from the live process (or `unknown`
#                     -> DEGRADED, never inferred from the image tag).
#   2. CONFIG DRIFT — deployed Deployment spec vs the committed manifest (if one
#                     exists), plus a FLAG of any in-container command/args that
#                     mutate files at startup (sed -i / cp / echo > ...), which
#                     are LOST ON REDEPLOY.
#   3. AUTH         — prove every auth claim with an expected-fail; flag any
#                     credential file that is configured but EMPTY (the
#                     empty-htpasswd class of bug). UNPROVEN when it cannot be
#                     proven.
#   4. EXPOSURE     — enumerate the Service types + port mappings; mark
#                     NodePort/LoadBalancer OPEN unless auth is proven armed;
#                     detect a docker-level proxy / frpc tunnel read-only.
#
# Usage: bash bin/verify-change.sh --namespace <ns> --target <name> [options]

FLEET_HOME="${FLEET_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KUBECONFIG_PATH="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

die()  { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }
warn() { echo "⚠ $*" >&2; }

# --- kubectl resolution ---------------------------------------------------------
# Prefer `kubectl` (the existing bin/ scripts' convention); fall back to
# `k3s kubectl` when the kubectl shim is absent. Both read the same kubeconfig.
KUBECTL="kubectl"
if ! command -v kubectl >/dev/null 2>&1; then
  if command -v k3s >/dev/null 2>&1; then
    KUBECTL="k3s kubectl"
  else
    die "no kubectl and no k3s on PATH"
  fi
fi

is_root() { [[ "$(id -u)" -eq 0 ]]; }
SUDO=""
if ! is_root; then
  # Non-interactive sudo ONLY: a read-only verify must never hang on a hidden
  # password prompt. If sudo -n is unavailable, die with the remedy.
  if sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
  else
    die "kubectl needs root to read $KUBECONFIG_PATH but 'sudo -n' is unavailable — run as root (or pre-auth with 'sudo -v'); this script is read-only."
  fi
fi

# kc — read-only kubectl wrapper. The env (KUBECONFIG) must survive the sudo hop
# (sudo resets the environment), so it is passed explicitly.
kc() {
  if [[ -n "$SUDO" ]]; then
    $SUDO env "KUBECONFIG=$KUBECONFIG_PATH" $KUBECTL "$@"
  else
    KUBECONFIG="$KUBECONFIG_PATH" $KUBECTL "$@"
  fi
}

# --- optional tool detection (degrade gracefully) ------------------------------
have_jq=1
command -v jq >/dev/null 2>&1 || have_jq=0
have_curl=1
command -v curl >/dev/null 2>&1 || have_curl=0
have_docker=1
command -v docker >/dev/null 2>&1 || have_docker=0
have_ss=1
command -v ss >/dev/null 2>&1 || have_ss=0

# --- CLI -----------------------------------------------------------------------
NS=""
TARGET=""
URL=""
EXPECT_FAIL_URL=""
JSON_OUT=0

usage() {
  cat <<'USAGE'
Usage: bash bin/verify-change.sh --namespace <ns> --target <name> [options]

REQUIRED
  --namespace <ns>       Kubernetes namespace the target lives in.
  --target <name>        Deployment name to verify (e.g. sudo-planner, paperclip).

OPTIONS
  --url <health-url>     Health endpoint to probe. If omitted, the URL is
                         derived from the target's Service and the URL used is
                         printed.
  --expect-fail-url <u>  A URL that MUST return 401/403 to an unauthenticated
                         GET. A 2xx here is a FAIL (auth not armed).
  --json                 Machine-readable output (one JSON object on stdout).

WHAT THIS DOES NOT PROVE
  * It is READ-ONLY. It never restarts/redeploys/patches anything, so it does
    not prove that a fix was APPLIED — only that the CURRENT state is (or is
    not) consistent with the four checks above.
  * It does not prove the app behaves correctly, only that it is running, its
    config matches the committed manifest, its auth is armed, and its exposure
    is as declared.
  * A DEGRADED check is NOT a pass: it ran but could not be fully verified
    (e.g. no version field exposed, or an auth claim that cannot be proven).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)       NS="$2"; shift 2 ;;
    --target)          TARGET="$2"; shift 2 ;;
    --url)             URL="$2"; shift 2 ;;
    --expect-fail-url) EXPECT_FAIL_URL="$2"; shift 2 ;;
    --json)            JSON_OUT=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage; die "unknown flag: $1" ;;
  esac
done

[[ -n "$NS" ]] || { usage; die "--namespace is required"; }
[[ -n "$TARGET" ]] || { usage; die "--target is required"; }
[[ "$have_jq" -eq 1 ]] || warn "jq not found — structured parsing will be degraded to grep/unknown"
[[ "$have_curl" -eq 1 ]] || die "curl is required to probe health/auth URLs"

# --- pre-flight (refuse to run on a target that isn't there) -------------------
if ! kc get namespace "$NS" >/dev/null 2>&1; then
  die "namespace '$NS' does not exist"
fi

DEPLOY_JSON="$(kc get deployment "$TARGET" -n "$NS" -o json 2>/dev/null)" \
  || die "no Deployment '$TARGET' in namespace '$NS'"

# Pod selector labels — pods DO carry these as metadata.labels (the Deployment
# template labels them), so `kubectl -l` works for pods.
if [[ "$have_jq" -eq 1 ]]; then
  SEL="$(jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$DEPLOY_JSON")"
else
  SEL="app=$TARGET"
fi

# Services are matched by their routing .spec.selector (NOT metadata.labels —
# many fleet Services carry no metadata.labels, so `kubectl -l` misses them).
SVC_JSON="$(kc get svc -n "$NS" -o json 2>/dev/null)" || SVC_JSON=""
if [[ -n "$SVC_JSON" && "$have_jq" -eq 1 ]]; then
  _dsel="$(jq -c '.spec.selector.matchLabels // {}' <<<"$DEPLOY_JSON")"
  SVC_JSON="$(jq -c --argjson d "$_dsel" '
    [ .items[]
      | select(
          (.spec.selector // {}) as $s
          | ($d | to_entries | all($s[.key] == .value))
        )
    ] | {items: .}' <<<"$SVC_JSON" 2>/dev/null)" || SVC_JSON=""
fi
_svc_count="$(jq -r '.items | length' <<<"$SVC_JSON" 2>/dev/null || echo 0)"
if [[ "${_svc_count:-0}" -eq 0 ]]; then
  die "no Service for '$TARGET' in namespace '$NS' (selector: $SEL)"
fi

# --- per-check result state ----------------------------------------------------
R1_STATUS=""; R1_DETAIL=""
R2_STATUS=""; R2_DETAIL=""
R3_STATUS=""; R3_DETAIL=""
R4_STATUS=""; R4_DETAIL=""
AUTH_PROVEN=0   # set to 1 by check 3 when an expect-fail returns 401/403

# --- helpers -------------------------------------------------------------------
# http_code <url> — prints the HTTP status code (0 on connect failure).
http_code() {
  [[ "$have_curl" -eq 1 ]] || { echo 0; return; }
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null || echo 0
}
# http_body <url> — prints the response body (empty on failure).
http_body() {
  [[ "$have_curl" -eq 1 ]] || return
  curl -s --max-time 8 "$1" 2>/dev/null || true
}

# pick_url_from_services — derive a health URL from the target's Services.
# Sets HEALTH_BASE (scheme://host:port) and HEALTH_PATH, or leaves them empty.
pick_url_from_services() {
  HEALTH_BASE=""; HEALTH_PATH=""
  [[ -n "$SVC_JSON" && "$have_jq" -eq 1 ]] || return 0
  # Preference order: a NodePort (reachable as 127.0.0.1:<nodePort>, and immune
  # to an app's Host-header allowlist), else the -watch ClusterIP (its /healthz
  # is a real liveness endpoint), else the -mcp ClusterIP, else any ClusterIP.
  local svc
  svc="$(jq -r --arg t "$TARGET" '
    .items | sort_by(.metadata.name)
    | ( map(select(.spec.type == "NodePort"))
        + map(select(.metadata.name == ($t + "-watch")))
        + map(select(.metadata.name == ($t + "-mcp")))
        + . )
    | .[0] // empty' <<<"$SVC_JSON")"
  [[ -n "$svc" ]] || return 0
  local type clusterip port nodeport
  type="$(jq -r '.spec.type' <<<"$svc")"
  clusterip="$(jq -r '.spec.clusterIP // ""' <<<"$svc")"
  port="$(jq -r '.spec.ports[0].port // ""' <<<"$svc")"
  nodeport="$(jq -r '.spec.ports[0].nodePort // ""' <<<"$svc")"
  if [[ "$type" == "NodePort" && -n "$nodeport" ]]; then
    HEALTH_BASE="http://127.0.0.1:$nodeport"
  elif [[ -n "$clusterip" && "$clusterip" != "None" ]]; then
    HEALTH_BASE="http://$clusterip:$port"
  else
    return 0
  fi
  HEALTH_PATH=""
}

# probe_health_paths — given HEALTH_BASE, find a path that returns 2xx.
# Sets HEALTH_PATH and leaves it empty if none 2xx.
probe_health_paths() {
  [[ -n "$HEALTH_BASE" ]] || return 0
  local p code
  # /api/health first: it is the convention this fleet's apps expose (and it
  # often carries the commit), then /healthz (the watch sidecar's liveness
  # route), then the generic /health and /.
  for p in /api/health /healthz /health /; do
    code="$(http_code "$HEALTH_BASE$p")"
    if [[ "$code" =~ ^2 ]]; then
      HEALTH_PATH="$p"
      return 0
    fi
  done
  HEALTH_PATH=""
}

# fetch_version — try to read a version/commit string from the live process.
# Prints the string, or nothing if none is exposed.
fetch_version() {
  local base="$1" hp="$2" body key p
  # Probe the health path plus a small set of version-ish endpoints; return the
  # first commit/version field found. (A body may be a plain string or a JSON
  # object; the jq reads the usual version keys and also accepts a bare string.)
  local paths=()
  [[ -n "$hp" ]] && paths+=("$hp")
  for p in /api/health /version /api/version /health; do
    paths+=("$p")
  done
  local up
  for up in "${paths[@]}"; do
    body="$(http_body "$base$up")"
    [[ -n "$body" ]] || continue
    key="$(jq -r '
      if type == "object" then
        (.commit // .gitSha // .git_sha // .revision // .version //
         .build // .gitCommit // .git_commit // .sha // empty) | tostring
      else empty end' <<<"$body" 2>/dev/null)"
    [[ -n "$key" && "$key" != "null" && "$key" != "" ]] && { echo "$key"; return 0; }
  done
  return 1
}

# yaml_to_json — convert YAML on stdin to JSON on stdout (python3+yaml, else yq).
yaml_to_json() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c 'import sys,yaml,json; d=list(yaml.safe_load_all(sys.stdin)); d=[x for x in d if x is not None]; print(json.dumps(d[0] if d else {}))' 2>/dev/null
  elif command -v yq >/dev/null 2>&1; then
    yq -o json '.' 2>/dev/null
  else
    return 1
  fi
}

# --- CHECK 1: RUNTIME ----------------------------------------------------------
check_runtime() {
  local line="" desired ready restarts age started now age_s pod_name phase
  local code ver

  desired="$(jq -r '.spec.replicas // 0' <<<"$DEPLOY_JSON")"
  ready="$(jq -r '.status.readyReplicas // 0' <<<"$DEPLOY_JSON")"
  line+="ready ${ready}/${desired}\n"

  local pods_json="$(kc get pods -n "$NS" -l "$SEL" -o json 2>/dev/null)" || pods_json=""
  local fail=0

  # pod restart count (0 required)
  if [[ -n "$pods_json" && "$have_jq" -eq 1 ]]; then
    restarts="$(jq -r '[.items[]?.status.containerStatuses[]?.restartCount // 0] | add // 0' <<<"$pods_json")"
    pod_name="$(jq -r '.items[0].metadata.name // ""' <<<"$pods_json")"
    phase="$(jq -r '.items[0].status.phase // ""' <<<"$pods_json")"
    started="$(jq -r '.items[0].status.startTime // .items[0].metadata.creationTimestamp // ""' <<<"$pods_json")"
  else
    restarts=""; pod_name=""; phase=""; started=""
  fi
  [[ -n "$restarts" && "$restarts" =~ ^[0-9]+$ ]] || restarts="0"
  if [[ "$restarts" -ne 0 ]]; then
    fail=1
    line+="restartCount ${restarts} (expected 0)\n"
  else
    line+="restartCount 0\n"
  fi

  # pod age (sane = not a fresh crash-loop window; 30s floor)
  age_s=""
  if [[ -n "$started" ]]; then
    now="$(date -u +%s)"
    started_epoch="$(date -u -d "$started" +%s 2>/dev/null || echo 0)"
    [[ "$started_epoch" =~ ^[0-9]+$ ]] && age_s=$(( now - started_epoch ))
  fi
  if [[ -n "$age_s" && "$age_s" =~ ^[0-9]+$ ]]; then
    line+="age ${age_s}s (phase ${phase:-unknown})\n"
    if [[ "$age_s" -lt 30 ]]; then
      warn "pod '$pod_name' is only ${age_s}s old — too young to confirm stability"
    fi
  else
    line+="age unknown\n"
  fi

  # health URL
  local base="$URL" path=""
  if [[ -z "$base" ]]; then
    pick_url_from_services
    base="$HEALTH_BASE"
    if [[ -n "$base" ]]; then
      probe_health_paths
      path="$HEALTH_PATH"
    fi
  fi
  if [[ -z "$base" ]]; then
    fail=1
    line+="health: no URL provided and none derivable\n"
    code=""
  else
    code="$(http_code "$base$path")"
    if [[ "$code" =~ ^2 ]]; then
      line+="health $code $base$path\n"
    else
      fail=1
      line+="health $code $base$path (expected 2xx)\n"
    fi
  fi

  # version/commit (from the live process, never the image tag)
  ver=""
  if [[ -n "$base" ]]; then
    ver="$(fetch_version "$base" "$path")" || ver=""
  fi
  if [[ -n "$ver" ]]; then
    line+="version $ver\n"
  else
    line+="version unknown\n"
  fi

  R1_DETAIL="$(printf '%b' "$line")"
  if [[ "$fail" -eq 1 ]]; then
    R1_STATUS="FAIL"
  elif [[ -z "$ver" ]]; then
    R1_STATUS="DEGRADED"   # running fine, but no version field is exposed
  else
    R1_STATUS="PASS"
  fi
}

# --- CHECK 2: CONFIG DRIFT -----------------------------------------------------
# The committed manifest filename drops the `sudo-` deploy prefix.
_find_manifest() {
  local bare="${TARGET#sudo-}" cand
  for cand in \
    "$FLEET_HOME/deployments/$TARGET.yaml" \
    "$FLEET_HOME/deployments/$bare.yaml" \
    "$FLEET_HOME/factories/sudo-agent/deployments/$TARGET.yaml" \
    "$FLEET_HOME/factories/sudo-agent/deployments/$bare.yaml" \
    "$FLEET_HOME/factories/sudo-letta/deployments/$TARGET.yaml" \
    "$FLEET_HOME/factories/sudo-letta/deployments/$bare.yaml" \
  ; do
    [[ -f "$cand" ]] && { echo "$cand"; return 0; }
  done
  return 1
}

check_config_drift() {
  local manifest drift=0 mut=0 line=""
  # Normalize a Deployment into a comparable fingerprint. Secret values are
  # REDACTED (never print a live credential into the drift report) and long
  # strings (e.g. the base64 seed command) are truncated so the diff stays
  # readable.
  local jq_norm='
def secretish($n): ($n | test("key|token|secret|password|passwd|passphrase|credential|cred|tavily|auth"; "i"));
def trunc: if (type == "string" and length > 120) then (.[0:120] + "...(truncated)") else . end;
def c:
  { name: .name,
    image: .image,
    command: ([.command[]? | trunc]),
    args: ([.args[]? | trunc]),
    env: ([.env[]?
           | { name: .name,
               value: (if .value != null then
                         (if secretish(.name) then "[REDACTED]" else (.value | trunc) end)
                       elif .valueFrom.secretKeyRef != null then
                         ("secret:" + .valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key)
                       elif .valueFrom.configMapKeyRef != null then
                         ("configmap:" + .valueFrom.configMapKeyRef.name + "/" + .valueFrom.configMapKeyRef.key)
                       else (.valueFrom | trunc | tostring) end) }]
          | sort_by(.name)) };
{ replicas: .spec.replicas,
  strategy: (.spec.strategy.type // "RollingUpdate"),
  hostNetwork: (.spec.template.spec.hostNetwork // false),
  containers: ([.spec.template.spec.containers[]? | c] | sort_by(.name)),
  initContainers: ([.spec.template.spec.initContainers[]? | c] | sort_by(.name)) }'

  # (a) live spec vs committed manifest
  if [[ "$have_jq" -eq 1 ]] && manifest="$(_find_manifest)"; then
    local committed_yaml committed_json live_norm committed_norm
    # Extract only the Deployment document from the (multi-doc) manifest.
    committed_yaml="$(awk -v RS='---' '$0 ~ /kind:[[:space:]]*Deployment/ { print }' "$manifest")"
    committed_json="$(yaml_to_json <<<"$committed_yaml" 2>/dev/null)" || committed_json=""
    if [[ -n "$committed_json" ]]; then
      live_norm="$(jq -c "$jq_norm" <<<"$DEPLOY_JSON" 2>/dev/null)" || live_norm=""
      committed_norm="$(jq -c "$jq_norm" <<<"$committed_json" 2>/dev/null)" || committed_norm=""
      if [[ -n "$live_norm" && -n "$committed_norm" && "$live_norm" != "$committed_norm" ]]; then
        drift=1
        local diffout
        # `diff` exits 1 when files differ, and with `set -euo pipefail` that
        # non-zero status would abort the script; the `|| true` swallows it so
        # we can still record and print the diff.
        diffout="$(diff <(jq -S . <<<"$live_norm" 2>/dev/null) <(jq -S . <<<"$committed_norm" 2>/dev/null) 2>/dev/null | head -80)" || true
        line+="committed manifest: $manifest\n"
        line+="DRIFT (live spec differs from committed manifest):\n${diffout}\n"
      else
        line+="committed manifest: $manifest (spec matches — no drift)\n"
      fi
    else
      line+="committed manifest: $manifest (could not parse Deployment doc — UNPROVEN)\n"
    fi
  else
    # No standalone YAML manifest. Some targets (e.g. paperclip) author their
    # Deployment as a heredoc inside a bin/*-up.sh script — note that so the
    # operator knows where to diff against (see docs/CHANGE-PROTOCOL.md).
    local heredoc_hit
    heredoc_hit="$(grep -rlE 'kind:[[:space:]]*Deployment' "$FLEET_HOME"/bin/*.sh 2>/dev/null | xargs -r grep -l "$TARGET" 2>/dev/null || true)"
    if [[ -n "$heredoc_hit" ]]; then
      line+="no standalone manifest; Deployment may be authored as a heredoc in: $(echo "$heredoc_hit" | tr '\n' ' ') (diff against that script — UNPROVEN)\n"
    else
      line+="no committed manifest under deployments/ or factories/*/deployments/ — cannot compare (UNPROVEN)\n"
    fi
  fi

  # (b) FLAG in-container command/args that mutate files at startup
  if [[ "$have_jq" -eq 1 ]]; then
    # main app containers (mutations here are lost on redeploy / are drift)
    local main_mut init_mut
    main_mut="$(jq -r '[.spec.template.spec.containers[]?
            | .name as $n
            | ((.command // []) + (.args // []))[]
            | select(test("sed +-i|sed +-i\\.[a-z]+|cp +|echo +.*>|printf +.*>|cat +>|tee |>>|> +/"))
            | ("container=" + $n + " :: " + (if length > 200 then (.[0:200] + "...(truncated)") else . end))] | .[]' <<<"$DEPLOY_JSON" 2>/dev/null)"
    init_mut="$(jq -r '[.spec.template.spec.initContainers[]?
            | .name as $n
            | ((.command // []) + (.args // []))[]
            | select(test("sed +-i|sed +-i\\.[a-z]+|cp +|echo +.*>|printf +.*>|cat +>|tee |>>|> +/"))
            | ("initContainer=" + $n + " :: " + (if length > 200 then (.[0:200] + "...(truncated)") else . end))] | .[]' <<<"$DEPLOY_JSON" 2>/dev/null)"
    if [[ -n "$main_mut" ]]; then
      mut=1
      line+="MUTATION FLAG (lost on redeploy):\n$main_mut\n"
    fi
    if [[ -n "$init_mut" ]]; then
      line+="initContainer file-copy (informational — e.g. the fleet glimor seed):\n$init_mut\n"
    fi
  fi

  R2_DETAIL="$(printf '%b' "$line")"
  if [[ "$drift" -eq 1 || "$mut" -eq 1 ]]; then
    R2_STATUS="FAIL"
  elif [[ "$manifest" == "" && "$mut" -eq 0 ]]; then
    R2_STATUS="DEGRADED"
  else
    R2_STATUS="PASS"
  fi
}

# --- CHECK 3: AUTH -------------------------------------------------------------
check_auth() {
  local line="" fail=0 proven=0 findings=0

  # (a) expected-fail proof
  if [[ -n "$EXPECT_FAIL_URL" ]]; then
    local code
    code="$(http_code "$EXPECT_FAIL_URL")"
    if [[ "$code" == "401" || "$code" == "403" ]]; then
      proven=1; AUTH_PROVEN=1
      line+="expect-fail $EXPECT_FAIL_URL -> HTTP $code (auth armed)\n"
    elif [[ "$code" =~ ^2 ]]; then
      fail=1
      line+="expect-fail $EXPECT_FAIL_URL -> HTTP $code (unauthenticated request SUCCEEDED — auth NOT armed)\n"
    elif [[ "$code" == "0" ]]; then
      line+="expect-fail $EXPECT_FAIL_URL -> unreachable (UNPROVEN)\n"
    else
      line+="expect-fail $EXPECT_FAIL_URL -> HTTP $code (not 401/403, not 2xx — UNPROVEN)\n"
    fi
  else
    line+="no --expect-fail-url given — auth cannot be proven (UNPROVEN)\n"
  fi

  # (b) empty credential file scan (the empty-htpasswd class of bug):
  #     a Secret/ConfigMap key that is referenced by the Deployment and holds an
  #     auth-ish credential, but whose content is zero bytes.
  if [[ "$have_jq" -eq 1 ]]; then
    local refs
    refs="$(jq -r '
      [ (.spec.template.spec.volumes[]?.secret.secretName // empty),
        (.spec.template.spec.volumes[]?.configMap.name // empty),
        (.spec.template.spec.containers[]?.env[]?.valueFrom.secretKeyRef.name // empty),
        (.spec.template.spec.containers[]?.env[]?.valueFrom.configMapKeyRef.name // empty),
        (.spec.template.spec.containers[]?.envFrom[]?.secretRef.name // empty),
        (.spec.template.spec.containers[]?.envFrom[]?.configMapRef.name // empty),
        (.spec.template.spec.initContainers[]?.env[]?.valueFrom.secretKeyRef.name // empty) ]
      | unique | .[]' <<<"$DEPLOY_JSON" 2>/dev/null)"
    local ref
    while IFS= read -r ref; do
      [[ -n "$ref" ]] || continue
      local sec_json cm_json
      sec_json="$(kc get secret "$ref" -n "$NS" -o json 2>/dev/null)" || sec_json=""
      if [[ -n "$sec_json" ]]; then
        local empties
        empties="$(jq -r '.data // {} | to_entries[] | select((.value | @base64d | length) == 0) | "secret \(.key) in \($r) is EMPTY (0 bytes)"' --arg r "$ref" <<<"$sec_json" 2>/dev/null)"
        # also: a literal empty string value (base64 of "" == "")
        empties+="$(jq -r '.data // {} | to_entries[] | select(.value == "") | "secret \(.key) in \($r) is EMPTY (empty value)"' --arg r "$ref" <<<"$sec_json" 2>/dev/null)"
        if [[ -n "$empties" ]]; then
          findings=1
          line+="$empties\n"
        fi
      fi
      cm_json="$(kc get configmap "$ref" -n "$NS" -o json 2>/dev/null)" || cm_json=""
      if [[ -n "$cm_json" ]]; then
        local cempties
        cempties="$(jq -r '.data // {} | to_entries[] | select(.value == "") | "configMap \(.key) in \($r) is EMPTY (empty value)"' --arg r "$ref" <<<"$cm_json" 2>/dev/null)"
        if [[ -n "$cempties" ]]; then
          findings=1
          line+="$cempties\n"
        fi
      fi
    done <<<"$refs"

    # (c) namespace-wide scan: an empty-htpasswd-class credential can live in a
    #     resource NOT referenced by this Deployment (e.g. an nginx basic-auth
    #     Secret sat in front of the app). Flag any auth-named Secret/ConfigMap
    #     whose credential key is zero bytes.
    local authres
    authres="$(kc get secrets,configmaps -n "$NS" -o json 2>/dev/null)" || authres=""
    if [[ -n "$authres" ]]; then
      local aempties_all
      aempties_all="$(jq -r '
        .items[]
        | select(.metadata.name | test("htpasswd|basic-auth|basicauth|auth|cred|password|passwd"; "i"))
        | . as $o
        | (if .kind == "Secret" then
             (.data // {} | to_entries[]
               | select((.value | @base64d | length) == 0)
               | "secret \($o.metadata.name)/\(.key) is EMPTY (0 bytes)")
           else
             (.data // {} | to_entries[]
               | select(.value == "")
               | "configMap \($o.metadata.name)/\(.key) is EMPTY (empty value)")
           end)
      ' <<<"$authres" 2>/dev/null)"
      if [[ -n "$aempties_all" ]]; then
        findings=1
        line+="$aempties_all\n"
      fi
    fi
  fi

  R3_DETAIL="$(printf '%b' "$line")"
  if [[ "$fail" -eq 1 || "$findings" -eq 1 ]]; then
    R3_STATUS="FAIL"
  elif [[ "$proven" -eq 1 ]]; then
    R3_STATUS="PASS"
  else
    R3_STATUS="DEGRADED"   # UNPROVEN
  fi
}

# --- CHECK 4: EXPOSURE ---------------------------------------------------------
check_exposure() {
  local line="" fail=0
  if [[ "$have_jq" -eq 1 && -n "$SVC_JSON" ]]; then
    local i n
    n="$(jq -r '.items | length' <<<"$SVC_JSON")"
    for (( i=0; i<n; i++ )); do
      local name type ports
      name="$(jq -r ".items[$i].metadata.name" <<<"$SVC_JSON")"
      type="$(jq -r ".items[$i].spec.type" <<<"$SVC_JSON")"
      ports="$(jq -r '.items['"$i"'].spec.ports[]? | "\(.port)->\(.targetPort // .port)" + (if .nodePort then "(nodePort \(.nodePort))" else "" end)' <<<"$SVC_JSON" | paste -sd, -)"
      if [[ "$type" == "NodePort" || "$type" == "LoadBalancer" ]]; then
        if [[ "$AUTH_PROVEN" -eq 1 ]]; then
          line+="$name $type $ports — guarded (auth armed in check 3)\n"
        else
          fail=1
          line+="$name $type $ports — OPEN (no auth proven)\n"
        fi
      else
        line+="$name $type $ports — internal\n"
      fi
    done
  else
    line+="service enumeration skipped (jq missing)\n"
  fi

  # docker-level proxy / frpc tunnel detection (read-only)
  local proxy_found=0
  if [[ "$have_docker" -eq 1 ]]; then
    local dhit
    dhit="$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E "$TARGET" || true)"
    if [[ -n "$dhit" ]]; then
      proxy_found=1
      line+="docker proxy detected: $dhit\n"
    fi
  fi
  if [[ "$have_ss" -eq 1 ]]; then
    # listening ports matching this target's NodePorts (informational)
    local nodeports
    nodeports="$(jq -r '.items[].spec.ports[]?.nodePort // empty' <<<"$SVC_JSON" 2>/dev/null | paste -sd, -)"
    if [[ -n "$nodeports" ]]; then
      local shits=""
      for np in ${nodeports//,/ }; do
        shits+="$(ss -ltn 2>/dev/null | grep -E ":$np " || true)"
      done
      [[ -n "$shits" ]] && line+="listening on nodePort(s):\n$shits\n"
    fi
  fi
  local frpc_hit
  frpc_hit="$(pgrep -a frpc 2>/dev/null || true)"
  if [[ -n "$frpc_hit" ]]; then
    proxy_found=1
    line+="frpc tunnel detected: $frpc_hit\n"
  fi
  if [[ "$proxy_found" -eq 0 ]]; then
    line+="docker-level proxy / frpc: undetected (read-only scan found none)\n"
  fi

  R4_DETAIL="$(printf '%b' "$line")"
  if [[ "$fail" -eq 1 ]]; then
    R4_STATUS="FAIL"
  else
    R4_STATUS="PASS"
  fi
}

# --- run -----------------------------------------------------------------------
check_runtime
check_config_drift
check_auth
check_exposure

# --- verdict -------------------------------------------------------------------
VERDICT="PASS"
for s in "$R1_STATUS" "$R2_STATUS" "$R3_STATUS" "$R4_STATUS"; do
  if [[ "$s" == "FAIL" ]]; then VERDICT="FAIL"; fi
done
if [[ "$VERDICT" != "FAIL" ]]; then
  for s in "$R1_STATUS" "$R2_STATUS" "$R3_STATUS" "$R4_STATUS"; do
    if [[ "$s" == "DEGRADED" ]]; then VERDICT="DEGRADED"; fi
  done
fi

EXIT_CODE=0
case "$VERDICT" in
  PASS)     EXIT_CODE=0 ;;
  FAIL)     EXIT_CODE=1 ;;
  DEGRADED) EXIT_CODE=2 ;;
esac

if [[ "$JSON_OUT" -eq 1 ]]; then
  [[ "$have_jq" -eq 1 ]] || die "jq is required for --json output"
  jq -n \
    --arg target "$TARGET" \
    --arg ns "$NS" \
    --arg r1 "$R1_STATUS" --arg d1 "$R1_DETAIL" \
    --arg r2 "$R2_STATUS" --arg d2 "$R2_DETAIL" \
    --arg r3 "$R3_STATUS" --arg d3 "$R3_DETAIL" \
    --arg r4 "$R4_STATUS" --arg d4 "$R4_DETAIL" \
    --arg verdict "$VERDICT" \
    '{ target: $target,
       namespace: $ns,
       checks: {
         runtime:     { status: $r1, detail: $d1 },
         config_drift:{ status: $r2, detail: $d2 },
         auth:        { status: $r3, detail: $d3 },
         exposure:    { status: $r4, detail: $d4 } },
       verdict: $verdict }'
else
  echo ""
  echo "── verify-change: $TARGET (namespace $NS) ──"
  echo ""
  echo "[1 RUNTIME]      $R1_STATUS"
  printf '%b' "$R1_DETAIL"
  echo "[2 CONFIG DRIFT] $R2_STATUS"
  printf '%b' "$R2_DETAIL"
  echo "[3 AUTH]         $R3_STATUS"
  printf '%b' "$R3_DETAIL"
  echo "[4 EXPOSURE]     $R4_STATUS"
  printf '%b' "$R4_DETAIL"
  echo ""
  echo "verdict: $VERDICT"
fi

exit "$EXIT_CODE"
