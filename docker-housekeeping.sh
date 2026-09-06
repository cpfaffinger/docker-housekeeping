#!/usr/bin/env bash
# =============================================================================
# docker-housekeeping - all-in-one maintenance for Docker hosts
#
#   Phase 1  compose    : pull/build every project in /etc/docker/compose and
#                         restart docker-compose@<project> when a new image
#                         is available
#   Phase 2  dockerweb  : build the shared web images from
#                         /home/dockerweb/_template* and restart every
#                         dockerweb instance that still runs an outdated image
#   Phase 3  cleanup    : remove stopped containers, unused images, volumes,
#                         networks and build cache - each with a cooldown
#   Phase 4  report     : e-mail on success / error (SMTP or local sendmail)
#
# Configuration: /etc/docker-housekeeping.conf (see docker-housekeeping.conf.example)
#
# Usage:
#   docker-housekeeping [--config FILE] [--dry-run] [--phase compose,dockerweb,cleanup]
#                       [--no-mail] [--test-mail] [--verbose] [--show-config]
#
# Replaces: buildAllImages.sh, updateAllComposer(s).sh, docker-cleanup.timer,
#           "docker system prune -f" cron lines
# =============================================================================
set -uo pipefail
export LC_ALL=C.UTF-8
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# BuildKit attaches provenance/SBOM attestations by default. With the containerd
# image store that changes the image ID on every build even when nothing changed,
# which would look like a new image and restart every instance daily.
export BUILDX_NO_DEFAULT_ATTESTATIONS=1

VERSION="1.1.5"
SCRIPT_NAME="docker-housekeeping"

# -----------------------------------------------------------------------------
# Defaults (overridden by the config file)
# -----------------------------------------------------------------------------
CONFIG_FILE="/etc/docker-housekeeping.conf"

# General
LOG_FILE="/var/log/docker-housekeeping.log"
STATE_DIR="/var/lib/docker-housekeeping"
LOCK_FILE="/run/lock/docker-housekeeping.lock"
HEALTH_TIMEOUT=120            # seconds to wait for containers to be running/healthy after a restart
DOCKER_BIN="docker"

# Phase 1: compose projects
COMPOSE_ENABLED="auto"        # true|false|auto (auto = run when COMPOSE_DIR exists)
COMPOSE_DIR="/etc/docker/compose"
COMPOSE_EXCLUDE=""            # space separated project names/globs, e.g. "vision-api.old *.bak"
COMPOSE_PULL="true"           # docker compose pull
COMPOSE_BUILD="true"          # also rebuild projects that contain build: sections
COMPOSE_BUILD_PULL="true"     # refresh base images while building (--pull)
COMPOSE_RESTART="true"        # restart on new image (false = report only)
COMPOSE_RESTART_METHOD="auto" # auto|systemd|compose
COMPOSE_UNIT_TEMPLATE="docker-compose@%s.service"

# Phase 2: dockerweb templates + instances
DOCKERWEB_ENABLED="auto"      # true|false|auto (auto = run when DOCKERWEB_DIR exists)
DOCKERWEB_DIR="/home/dockerweb"
DOCKERWEB_TEMPLATE_GLOB="_template*"
DOCKERWEB_EXCLUDE=""          # instances (directory names/globs) that are never restarted automatically
DOCKERWEB_BUILD="true"        # build the templates
DOCKERWEB_BUILD_PULL="true"   # refresh the base image (php:8.x-apache) while building
DOCKERWEB_RESTART="true"      # restart instances running an outdated image (false = report only)
DOCKERWEB_RESTART_METHOD="auto" # auto|systemd|compose
DOCKERWEB_RESTART_DELAY=5     # seconds between instance restarts
DOCKERWEB_RESTART_MAX=0       # max. restarts per run (0 = unlimited)
DOCKERWEB_UNIT_TEMPLATE="dockerweb@%s.service"

# Phase 3: cleanup
CLEANUP_ENABLED="true"
CLEANUP_CONTAINERS="true"
CLEANUP_CONTAINER_MIN_AGE_DAYS=7      # remove stopped containers only after X days
CLEANUP_IMAGES="true"
CLEANUP_IMAGE_COOLDOWN_DAYS=3         # remove an image only X days after it was last used
CLEANUP_IMAGE_KEEP_REGEX=""           # regex on repo:tag - matching images are never removed
CLEANUP_VOLUMES="true"                # volume cleanup (can be switched off)
CLEANUP_VOLUMES_NAMED="true"          # also named volumes (false = anonymous volumes only)
CLEANUP_VOLUME_COOLDOWN_DAYS=14       # remove a volume only X days after it was last used
CLEANUP_VOLUME_KEEP_REGEX=""          # regex on volume names - matching volumes are never removed
CLEANUP_NETWORKS="true"
CLEANUP_BUILD_CACHE="true"
CLEANUP_BUILD_CACHE_MAX_AGE_DAYS=7    # build cache entries unused for longer than this
CLEANUP_BUILD_CACHE_KEEP_STORAGE=""   # e.g. "10GB" - additionally cap the build cache
CLEANUP_EMERGENCY_DISK_PERCENT=90     # above this usage of the docker root all cooldowns are ignored (0 = off)

# Phase 4: mail
MAIL_ENABLED="true"
MAIL_ON_SUCCESS="true"
MAIL_ON_ERROR="true"
MAIL_ONLY_ON_CHANGE="false"   # true = success mail only when something changed / warnings exist
MAIL_TO=""                    # space separated
MAIL_FROM=""                  # empty = docker-housekeeping@<fqdn>
MAIL_SUBJECT_PREFIX="[docker-housekeeping]"
MAIL_INCLUDE_LOG="true"
MAIL_LOG_MAX_LINES=400
MAIL_TRANSPORT="auto"         # auto|smtp|sendmail (auto = smtp when MAIL_SMTP_HOST is set)
MAIL_SMTP_HOST=""
MAIL_SMTP_PORT=25
MAIL_SMTP_TLS="none"          # none|starttls|ssl
MAIL_SMTP_USER=""
MAIL_SMTP_PASSWORD=""
MAIL_SMTP_INSECURE="false"    # true = do not verify the server certificate
MAIL_SENDMAIL_BIN="/usr/sbin/sendmail"

# -----------------------------------------------------------------------------
# Runtime state
# -----------------------------------------------------------------------------
DRY_RUN=false
VERBOSE=false
NO_MAIL=false
TEST_MAIL=false
SHOW_CONFIG=false
PHASES=""                     # empty = all enabled phases
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
START_TS=$(date +%s)
NOW=$START_TS

ERRORS=0
WARNINGS=0
CHANGES=0
declare -a REPORT_CHANGES=()
declare -a REPORT_ERRORS=()
declare -a REPORT_WARNINGS=()
declare -a LOG_LINES=()
RECLAIMED_BYTES=0
DISK_BEFORE=""
DISK_AFTER=""
DOCKER_ROOT="/var/lib/docker"
EMERGENCY=false
RESTARTS_DONE=0
LOCK_FD=""

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
_log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local line="[$ts] [$level] $msg"
  echo "$line"
  LOG_LINES+=("$line")
  if [ -n "$LOG_FILE" ]; then echo "$line" >> "$LOG_FILE" 2>/dev/null || true; fi
}
log_info()   { _log "INFO" "$@"; }
log_debug()  { if $VERBOSE; then _log "DEBUG" "$@"; fi; return 0; }
log_warn()   { _log "WARN" "$@"; WARNINGS=$((WARNINGS+1)); REPORT_WARNINGS+=("$*"); }
log_error()  { _log "ERROR" "$@"; ERRORS=$((ERRORS+1)); REPORT_ERRORS+=("$*"); }
log_change() { _log "CHANGE" "$@"; CHANGES=$((CHANGES+1)); REPORT_CHANGES+=("$*"); }

finish() {
  local rc="${1:-0}"
  [ -n "$LOCK_FD" ] && flock -u "$LOCK_FD" 2>/dev/null
  exit "$rc"
}
die() { log_error "$@"; finish 2; }

# run: execute a command unless in dry-run mode
run() {
  if $DRY_RUN; then
    log_info "[dry-run] $*"
    return 0
  fi
  log_debug "exec: $*"
  "$@"
}

is_true() { case "${1,,}" in true|yes|1|on) return 0;; *) return 1;; esac; }

human_bytes() {
  local b=${1:-0}
  if   [ "$b" -ge 1073741824 ]; then awk "BEGIN{printf \"%.2f GB\", $b/1073741824}"
  elif [ "$b" -ge 1048576 ];    then awk "BEGIN{printf \"%.1f MB\", $b/1048576}"
  elif [ "$b" -ge 1024 ];       then awk "BEGIN{printf \"%.0f kB\", $b/1024}"
  else printf '%d B' "$b"; fi
}

# "1.234GB" / "512MB" -> bytes (docker prune output)
parse_size_to_bytes() {
  local s="$1" num unit
  num=$(echo "$s" | grep -oE '^[0-9.]+'); unit=$(echo "$s" | grep -oE '[A-Za-z]+$')
  [ -z "$num" ] && { echo 0; return; }
  case "${unit^^}" in
    B)   awk "BEGIN{printf \"%d\", $num}";;
    KB)  awk "BEGIN{printf \"%d\", $num*1000}";;
    MB)  awk "BEGIN{printf \"%d\", $num*1000000}";;
    GB)  awk "BEGIN{printf \"%d\", $num*1000000000}";;
    TB)  awk "BEGIN{printf \"%d\", $num*1000000000000}";;
    KIB) awk "BEGIN{printf \"%d\", $num*1024}";;
    MIB) awk "BEGIN{printf \"%d\", $num*1048576}";;
    GIB) awk "BEGIN{printf \"%d\", $num*1073741824}";;
    *) echo 0;;
  esac
}

# RFC3339 (docker inspect) -> epoch; empty / 0001-01-01 -> 0
to_epoch() {
  local t="$1"
  case "$t" in ""|0001-01-01*) echo 0; return;; esac
  date -d "$t" +%s 2>/dev/null || echo 0
}

glob_match_any() {  # glob_match_any NAME "glob1 glob2 ..."
  local name="$1" pat
  for pat in $2; do [[ "$name" == $pat ]] && return 0; done
  return 1
}

disk_usage_line() { df -h --output=size,used,avail,pcent "$DOCKER_ROOT" 2>/dev/null | tail -1 | awk '{print "size="$1" used="$2" avail="$3" ("$4")"}'; }
disk_usage_pct()  { df --output=pcent "$DOCKER_ROOT" 2>/dev/null | tail -1 | tr -dc '0-9'; }

# -----------------------------------------------------------------------------
# Arguments & config
# -----------------------------------------------------------------------------
usage() {
  sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
  cat <<USAGE

Options:
  --config FILE        configuration file (default: $CONFIG_FILE)
  --dry-run            show what would be done, change nothing
  --phase LIST         run only these phases: compose,dockerweb,cleanup (comma separated)
  --no-mail            do not send a mail
  --test-mail          send a test mail and exit
  --show-config        print the effective configuration and exit
  --verbose            debug output
  --version / --help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift;;
    --config=*) CONFIG_FILE="${1#*=}";;
    --dry-run|-n) DRY_RUN=true;;
    --phase) PHASES="$2"; shift;;
    --phase=*) PHASES="${1#*=}";;
    --no-mail) NO_MAIL=true;;
    --test-mail) TEST_MAIL=true;;
    --show-config) SHOW_CONFIG=true;;
    --verbose|-v) VERBOSE=true;;
    --version) echo "$SCRIPT_NAME $VERSION"; exit 0;;
    --help|-h) usage; exit 0;;
    *) echo "Unknown option: $1" >&2; usage; exit 1;;
  esac
  shift
done

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE" || { echo "Could not load config $CONFIG_FILE" >&2; exit 1; }
else
  echo "WARN: config $CONFIG_FILE not found, using defaults" >&2
fi

phase_selected() {  # phase_selected NAME -> 0 when selected via --phase (or nothing selected)
  [ -z "$PHASES" ] && return 0
  [[ ",$PHASES," == *",$1,"* ]]
}

if $SHOW_CONFIG; then
  for v in $(compgen -v | grep -E '^(LOG_FILE|STATE_DIR|LOCK_FILE|HEALTH_TIMEOUT|COMPOSE_|DOCKERWEB_|CLEANUP_|MAIL_)'); do
    val="${!v}"; [[ "$v" == *PASSWORD* ]] && [ -n "$val" ] && val="********"
    printf '%-36s = %s\n' "$v" "$val"
  done
  exit 0
fi

# -----------------------------------------------------------------------------
# Preparation
# -----------------------------------------------------------------------------
mkdir -p "$STATE_DIR" "$(dirname "$LOCK_FILE")" 2>/dev/null
touch "$LOG_FILE" 2>/dev/null || LOG_FILE=""

exec {LOCK_FD}>"$LOCK_FILE"
if ! flock -n "$LOCK_FD"; then
  echo "Another $SCRIPT_NAME is already running ($LOCK_FILE)" >&2
  exit 3
fi

if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then die "docker not found"; fi
if ! $DOCKER_BIN info >/dev/null 2>&1; then die "docker daemon not reachable"; fi
DOCKER_ROOT=$($DOCKER_BIN info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
[ -d "$DOCKER_ROOT" ] || DOCKER_ROOT="/"

# -----------------------------------------------------------------------------
# Compose helpers
# -----------------------------------------------------------------------------
find_compose_file() {  # find_compose_file DIR -> file name or 1
  local d="$1" f
  for f in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    [ -f "$d/$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

compose_has_build() {  # compose_has_build DIR
  (cd "$1" && $DOCKER_BIN compose config 2>/dev/null | grep -qE '^\s+build:')
}

compose_images() {     # compose_images DIR -> image references of all services
  (cd "$1" && $DOCKER_BIN compose config --images 2>/dev/null)
}

compose_container_ids() {  # all containers of the project (including stopped ones)
  (cd "$1" && $DOCKER_BIN compose ps -aq 2>/dev/null)
}

# outdated_containers DIR -> lines "container image_ref" for containers whose
# running image is no longer the image the tag currently points to.
outdated_containers() {
  local d="$1" cid running cfg name current
  for cid in $(compose_container_ids "$d"); do
    read -r running cfg name <<<"$($DOCKER_BIN inspect -f '{{.Image}} {{.Config.Image}} {{.Name}}' "$cid" 2>/dev/null)" || continue
    [ -z "$cfg" ] && continue
    current=$($DOCKER_BIN image inspect -f '{{.Id}}' "$cfg" 2>/dev/null) || continue
    if [ "$running" != "$current" ]; then
      echo "${name#/} $cfg"
    fi
  done
}

unit_exists_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# wait_healthy DIR TIMEOUT -> 0 when all containers are running and (healthy | no healthcheck)
wait_healthy() {
  local d="$1" timeout="${2:-$HEALTH_TIMEOUT}" deadline cid st hs bad
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    bad=""
    for cid in $(compose_container_ids "$d"); do
      read -r st hs <<<"$($DOCKER_BIN inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
      case "$st/$hs" in
        running/none|running/healthy) ;;
        *) bad="$bad ${cid:0:12}:$st/$hs";;
      esac
    done
    [ -z "$bad" ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && { echo "$bad"; return 1; }
    sleep 3
  done
}

# restart_project DIR NAME UNIT METHOD [--no-build]
restart_project() {
  local d="$1" name="$2" unit="$3" method="$4" nobuild="${5:-}" out
  local use_systemd=false
  case "$method" in
    systemd) use_systemd=true;;
    compose) use_systemd=false;;
    *) unit_exists_active "$unit" && use_systemd=true;;
  esac
  if $use_systemd; then
    log_info "  restarting via systemctl restart $unit"
    if ! out=$(run systemctl restart "$unit" 2>&1); then
      log_error "  restart of $unit failed: $out"; return 1
    fi
  else
    log_info "  restarting via docker compose up -d ($d)"
    if ! out=$(cd "$d" && run $DOCKER_BIN compose up -d --remove-orphans $nobuild 2>&1); then
      log_error "  docker compose up for $name failed: $out"; return 1
    fi
  fi
  $DRY_RUN && return 0
  if out=$(wait_healthy "$d" "$HEALTH_TIMEOUT"); then
    log_info "  $name is up (healthy)"
    return 0
  else
    log_error "  $name not healthy ${HEALTH_TIMEOUT}s after restart:$out"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Phase 1: compose projects
# -----------------------------------------------------------------------------
phase_compose() {
  local dir name cf out outdated unit pullflag
  log_info "=== phase compose: $COMPOSE_DIR ==="
  for dir in "$COMPOSE_DIR"/*/; do
    [ -d "$dir" ] || continue
    dir=${dir%/}; name=$(basename "$dir")
    if glob_match_any "$name" "$COMPOSE_EXCLUDE"; then log_info "[$name] excluded (COMPOSE_EXCLUDE)"; continue; fi
    if ! cf=$(find_compose_file "$dir"); then log_warn "[$name] no compose file found, skipped"; continue; fi
    log_info "[$name] $dir/$cf"

    if is_true "$COMPOSE_PULL"; then
      if $DRY_RUN; then
        log_info "[$name] [dry-run] docker compose pull"
      else
        if ! out=$(cd "$dir" && $DOCKER_BIN compose pull --quiet --ignore-buildable 2>&1); then
          # older compose versions do not know --ignore-buildable -> retry without it
          if ! out=$(cd "$dir" && $DOCKER_BIN compose pull --quiet 2>&1); then
            log_error "[$name] docker compose pull failed: $(echo "$out" | grep -v 'obsolete' | tail -3 | tr '\n' ' ')"
            continue
          fi
        fi
        log_debug "[$name] pull: $out"
      fi
    fi

    if is_true "$COMPOSE_BUILD" && compose_has_build "$dir"; then
      pullflag=""; is_true "$COMPOSE_BUILD_PULL" && pullflag="--pull"
      log_info "[$name] project contains build:, building images $pullflag"
      if ! $DRY_RUN; then
        if ! out=$(cd "$dir" && $DOCKER_BIN compose build --quiet $pullflag 2>&1); then
          log_error "[$name] docker compose build failed: $(echo "$out" | tail -5 | tr '\n' ' ')"
          continue
        fi
      fi
    fi

    outdated=$(outdated_containers "$dir")
    if [ -z "$outdated" ]; then
      if [ -z "$(compose_container_ids "$dir")" ]; then
        log_info "[$name] no containers (not deployed) - nothing to restart"
      else
        log_info "[$name] up to date, no restart needed"
      fi
      continue
    fi
    log_info "[$name] outdated containers: $(echo "$outdated" | tr '\n' ';')"
    if ! is_true "$COMPOSE_RESTART"; then
      log_warn "[$name] new image available but restart disabled (COMPOSE_RESTART=false)"
      continue
    fi
    # shellcheck disable=SC2059
    unit=$(printf "$COMPOSE_UNIT_TEMPLATE" "$name")
    if restart_project "$dir" "$name" "$unit" "$COMPOSE_RESTART_METHOD"; then
      log_change "compose: $name restarted (new image: $(echo "$outdated" | awk '{print $2}' | sort -u | tr '\n' ' '))"
    fi
  done
}

# -----------------------------------------------------------------------------
# Phase 2: dockerweb templates + instances
# -----------------------------------------------------------------------------
phase_dockerweb() {
  local tdir tname cf img_ref before after out pullflag alt t0
  log_info "=== phase dockerweb: $DOCKERWEB_DIR ==="

  # --- build templates ---
  if is_true "$DOCKERWEB_BUILD"; then
    for tdir in "$DOCKERWEB_DIR"/$DOCKERWEB_TEMPLATE_GLOB/; do
      [ -d "$tdir" ] || continue
      tdir=${tdir%/}; tname=$(basename "$tdir")
      if ! cf=$(find_compose_file "$tdir"); then
        alt=$(ls "$tdir" 2>/dev/null | grep -E '^(docker-)?compose\.ya?ml\.' | tr '\n' ' ')
        log_warn "[$tname] template has no docker-compose.yml (found: ${alt:-nothing}) - build skipped"
        continue
      fi
      img_ref=$(compose_images "$tdir" | head -1)
      [ -z "$img_ref" ] && { log_warn "[$tname] cannot determine image name (docker compose config --images)"; continue; }
      before=$($DOCKER_BIN image inspect -f '{{.Id}}' "$img_ref" 2>/dev/null || echo "none")
      pullflag=""; is_true "$DOCKERWEB_BUILD_PULL" && pullflag="--pull"
      log_info "[$tname] building $img_ref $pullflag (current: ${before:0:19})"
      if $DRY_RUN; then log_info "[$tname] [dry-run] docker compose build $pullflag"; continue; fi
      t0=$(date +%s)
      if ! out=$(cd "$tdir" && $DOCKER_BIN compose build --quiet $pullflag 2>&1); then
        log_error "[$tname] build failed: $(echo "$out" | tail -8 | tr '\n' ' ')"
        continue
      fi
      after=$($DOCKER_BIN image inspect -f '{{.Id}}' "$img_ref" 2>/dev/null || echo "none")
      if [ "$before" != "$after" ]; then
        log_change "dockerweb: template $tname -> new image $img_ref (${before:7:12} -> ${after:7:12}, $(( $(date +%s) - t0 ))s)"
      else
        log_info "[$tname] image $img_ref unchanged ($(( $(date +%s) - t0 ))s)"
      fi
    done
  fi

  # --- restart instances that run an outdated image ---
  local idir iname outdated unit n=0
  for idir in "$DOCKERWEB_DIR"/*/; do
    [ -d "$idir" ] || continue
    idir=${idir%/}; iname=$(basename "$idir")
    # shellcheck disable=SC2053
    [[ "$iname" == $DOCKERWEB_TEMPLATE_GLOB ]] && continue
    glob_match_any "$iname" "$DOCKERWEB_EXCLUDE" && { log_info "[$iname] excluded (DOCKERWEB_EXCLUDE)"; continue; }
    find_compose_file "$idir" >/dev/null || continue
    [ -z "$(compose_container_ids "$idir")" ] && { log_debug "[$iname] no containers (not deployed)"; continue; }
    outdated=$(outdated_containers "$idir")
    [ -z "$outdated" ] && { log_debug "[$iname] up to date"; continue; }
    n=$((n+1))
    log_info "[$iname] runs an outdated image: $(echo "$outdated" | tr '\n' ' ')"
    if ! is_true "$DOCKERWEB_RESTART"; then
      log_warn "[$iname] restart required but DOCKERWEB_RESTART=false"
      continue
    fi
    if [ "$DOCKERWEB_RESTART_MAX" -gt 0 ] && [ "$RESTARTS_DONE" -ge "$DOCKERWEB_RESTART_MAX" ]; then
      log_warn "[$iname] restart postponed (DOCKERWEB_RESTART_MAX=$DOCKERWEB_RESTART_MAX reached)"
      continue
    fi
    # shellcheck disable=SC2059
    unit=$(printf "$DOCKERWEB_UNIT_TEMPLATE" "$iname")
    if restart_project "$idir" "$iname" "$unit" "$DOCKERWEB_RESTART_METHOD" "--no-build"; then
      log_change "dockerweb: instance $iname restarted ($(echo "$outdated" | awk '{print $2}' | sort -u | tr '\n' ' '))"
      RESTARTS_DONE=$((RESTARTS_DONE+1))
      $DRY_RUN || sleep "$DOCKERWEB_RESTART_DELAY"
    fi
  done
  [ "$n" -eq 0 ] && log_info "all dockerweb instances run the current image"
  return 0
}

# -----------------------------------------------------------------------------
# Phase 3: cleanup
# -----------------------------------------------------------------------------
declare -A ST_FIRST ST_LAST KEEP_KEYS   # key: img:<id> | vol:<name>
STATE_FILE=""

load_state() {
  STATE_FILE="$STATE_DIR/usage.tsv"
  [ -f "$STATE_FILE" ] || return 0
  local k f l
  while IFS=$'\t' read -r k f l _; do
    [ -z "$k" ] && continue
    ST_FIRST[$k]=$f; ST_LAST[$k]=$l
  done < "$STATE_FILE"
}
save_state() {   # keep only keys that still exist (KEEP_KEYS)
  $DRY_RUN && return 0
  local k tmp="$STATE_FILE.tmp"
  : > "$tmp"
  for k in "${!KEEP_KEYS[@]}"; do
    printf '%s\t%s\t%s\n' "$k" "${ST_FIRST[$k]:-$NOW}" "${ST_LAST[$k]:-0}" >> "$tmp"
  done
  mv "$tmp" "$STATE_FILE"
}

# touch_state KEY IN_USE(0/1) CREATED_EPOCH -> updates timestamps, sets TS_REF (reference time)
# reference time = last use, otherwise first sighting; never older than the creation time.
# Sets a global instead of printing so it is not run in a subshell (state must persist).
TS_REF=0
touch_state() {
  local k="$1" inuse="$2" created="$3" ref
  [ -z "${ST_FIRST[$k]:-}" ] && ST_FIRST[$k]=$NOW
  [ "$inuse" = 1 ] && ST_LAST[$k]=$NOW
  KEEP_KEYS[$k]=1
  ref=${ST_LAST[$k]:-0}
  [ "$ref" -eq 0 ] && ref=${ST_FIRST[$k]}
  [ "$created" -gt "$ref" ] && ref=$created
  TS_REF=$ref
}

cleanup_containers() {
  local cid name finished fe age_d out removed=0 min=$CLEANUP_CONTAINER_MIN_AGE_DAYS
  for cid in $($DOCKER_BIN ps -aq -f status=exited -f status=created -f status=dead 2>/dev/null); do
    read -r name finished <<<"$($DOCKER_BIN inspect -f '{{.Name}} {{.State.FinishedAt}}' "$cid" 2>/dev/null)"
    fe=$(to_epoch "$finished"); [ "$fe" -eq 0 ] && fe=$(to_epoch "$($DOCKER_BIN inspect -f '{{.Created}}' "$cid")")
    age_d=$(( (NOW - fe) / 86400 ))
    if $EMERGENCY || [ "$age_d" -ge "$min" ]; then
      log_info "  removing container ${name#/} (stopped for ${age_d}d)"
      if $DRY_RUN; then removed=$((removed+1))
      elif out=$($DOCKER_BIN rm "$cid" 2>&1); then removed=$((removed+1))
      else log_error "  docker rm ${name#/}: $out"; fi
    else
      log_debug "  container ${name#/} stopped for ${age_d}d < ${min}d, kept"
    fi
  done
  [ "$removed" -gt 0 ] && log_change "cleanup: $removed stopped containers removed"
  return 0
}

cleanup_images() {
  local -A used
  local id tags created ref age_d removed=0 freed=0 size k inuse out rc
  for id in $($DOCKER_BIN ps -aq 2>/dev/null | xargs -r $DOCKER_BIN inspect -f '{{.Image}}' 2>/dev/null); do used[$id]=1; done
  for id in $($DOCKER_BIN images -aq --no-trunc 2>/dev/null | sort -u); do
    read -r created size <<<"$($DOCKER_BIN image inspect -f '{{.Created}} {{.Size}}' "$id" 2>/dev/null)"
    tags=$($DOCKER_BIN image inspect -f '{{join .RepoTags " "}}' "$id" 2>/dev/null)
    k="img:$id"; inuse=0; [ -n "${used[$id]:-}" ] && inuse=1
    touch_state "$k" "$inuse" "$(to_epoch "$created")"; ref=$TS_REF
    [ "$inuse" = 1 ] && continue
    if [ -n "$CLEANUP_IMAGE_KEEP_REGEX" ] && echo "$tags" | grep -qE "$CLEANUP_IMAGE_KEEP_REGEX"; then
      log_debug "  image ${tags:-$id} protected by KEEP_REGEX"; continue
    fi
    age_d=$(( (NOW - ref) / 86400 ))
    if $EMERGENCY || [ "$age_d" -ge "$CLEANUP_IMAGE_COOLDOWN_DAYS" ]; then
      log_info "  removing image ${tags:-<none>} (${id:7:12}, $(human_bytes "${size:-0}"), unused for ${age_d}d)"
      if $DRY_RUN; then removed=$((removed+1)); freed=$((freed+${size:-0})); continue; fi
      if [ -n "$tags" ]; then out=$($DOCKER_BIN rmi $tags 2>&1); rc=$?; else out=$($DOCKER_BIN rmi "$id" 2>&1); rc=$?; fi
      if [ $rc -eq 0 ]; then removed=$((removed+1)); freed=$((freed+${size:-0})); unset "KEEP_KEYS[$k]"
      else log_warn "  docker rmi ${tags:-$id}: $(echo "$out" | tail -1)"; fi
    else
      log_debug "  image ${tags:-$id} unused for ${age_d}d < ${CLEANUP_IMAGE_COOLDOWN_DAYS}d, kept"
    fi
  done
  if [ "$removed" -gt 0 ]; then
    log_change "cleanup: $removed images removed (~$(human_bytes $freed))"
    RECLAIMED_BYTES=$((RECLAIMED_BYTES+freed))
  fi
  return 0
}

cleanup_volumes() {
  local -A used
  local v created ref age_d k inuse removed=0 out anon
  for v in $($DOCKER_BIN ps -aq 2>/dev/null | xargs -r $DOCKER_BIN inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null); do used[$v]=1; done
  for v in $($DOCKER_BIN volume ls -q 2>/dev/null); do
    anon=false; [[ "$v" =~ ^[0-9a-f]{64}$ ]] && anon=true
    created=$($DOCKER_BIN volume inspect -f '{{.CreatedAt}}' "$v" 2>/dev/null)
    k="vol:$v"; inuse=0; [ -n "${used[$v]:-}" ] && inuse=1
    touch_state "$k" "$inuse" "$(to_epoch "$created")"; ref=$TS_REF
    [ "$inuse" = 1 ] && continue
    if ! $anon && ! is_true "$CLEANUP_VOLUMES_NAMED"; then log_debug "  volume $v is named, CLEANUP_VOLUMES_NAMED=false"; continue; fi
    if [ -n "$CLEANUP_VOLUME_KEEP_REGEX" ] && echo "$v" | grep -qE "$CLEANUP_VOLUME_KEEP_REGEX"; then log_debug "  volume $v protected by KEEP_REGEX"; continue; fi
    age_d=$(( (NOW - ref) / 86400 ))
    if $EMERGENCY || [ "$age_d" -ge "$CLEANUP_VOLUME_COOLDOWN_DAYS" ]; then
      log_info "  removing volume $v ($( $anon && echo anonymous || echo named ), unused for ${age_d}d)"
      if $DRY_RUN; then removed=$((removed+1))
      elif out=$($DOCKER_BIN volume rm "$v" 2>&1); then removed=$((removed+1)); unset "KEEP_KEYS[$k]"
      else log_warn "  docker volume rm $v: $(echo "$out" | tail -1)"; fi
    else
      log_debug "  volume $v unused for ${age_d}d < ${CLEANUP_VOLUME_COOLDOWN_DAYS}d, kept"
    fi
  done
  [ "$removed" -gt 0 ] && log_change "cleanup: $removed volumes removed"
  return 0
}

cleanup_networks() {
  local out n
  if $DRY_RUN; then log_info "  [dry-run] docker network prune -f"; return 0; fi
  out=$($DOCKER_BIN network prune -f 2>&1) || { log_warn "  network prune: $out"; return 0; }
  n=$(echo "$out" | grep -vE '^(Deleted Networks:|Total|$)' | wc -l)
  [ "$n" -gt 0 ] && log_change "cleanup: $n unused networks removed"
  return 0
}

cleanup_build_cache() {
  local out args="-af" reclaimed b
  if ! $EMERGENCY; then args="$args --filter until=$(( CLEANUP_BUILD_CACHE_MAX_AGE_DAYS * 24 ))h"; fi
  [ -n "$CLEANUP_BUILD_CACHE_KEEP_STORAGE" ] && args="$args --keep-storage $CLEANUP_BUILD_CACHE_KEEP_STORAGE"
  if $DRY_RUN; then
    log_info "  [dry-run] docker builder prune $args ($($DOCKER_BIN system df --format '{{.Type}}: {{.Size}} reclaimable {{.Reclaimable}}' 2>/dev/null | grep -i 'build'))"
    return 0
  fi
  out=$($DOCKER_BIN builder prune $args 2>&1) || { log_warn "  builder prune: $(echo "$out" | tail -1)"; return 0; }
  reclaimed=$(echo "$out" | grep -oE 'Total reclaimed space: .*' | awk '{print $4$5}')
  b=$(parse_size_to_bytes "${reclaimed:-0B}")
  if [ "$b" -gt 0 ]; then log_change "cleanup: build cache pruned ($reclaimed)"; RECLAIMED_BYTES=$((RECLAIMED_BYTES+b)); else log_info "  build cache: nothing to prune"; fi
  return 0
}

phase_cleanup() {
  log_info "=== phase cleanup ==="
  local pct; pct=$(disk_usage_pct)
  if [ "${CLEANUP_EMERGENCY_DISK_PERCENT:-0}" -gt 0 ] && [ "${pct:-0}" -ge "$CLEANUP_EMERGENCY_DISK_PERCENT" ]; then
    EMERGENCY=true
    log_warn "emergency mode: $DOCKER_ROOT is ${pct}% full (>= ${CLEANUP_EMERGENCY_DISK_PERCENT}%), cooldowns are ignored"
  fi
  load_state
  if is_true "$CLEANUP_CONTAINERS";  then log_info "-- stopped containers (min. age ${CLEANUP_CONTAINER_MIN_AGE_DAYS}d)"; cleanup_containers; fi
  if is_true "$CLEANUP_IMAGES";      then log_info "-- unused images (cooldown ${CLEANUP_IMAGE_COOLDOWN_DAYS}d)"; cleanup_images; fi
  if is_true "$CLEANUP_VOLUMES";     then log_info "-- unused volumes (cooldown ${CLEANUP_VOLUME_COOLDOWN_DAYS}d, named: $CLEANUP_VOLUMES_NAMED)"; cleanup_volumes; else log_info "-- volumes: cleanup disabled"; fi
  if is_true "$CLEANUP_NETWORKS";    then log_info "-- unused networks"; cleanup_networks; fi
  if is_true "$CLEANUP_BUILD_CACHE"; then log_info "-- build cache (older than ${CLEANUP_BUILD_CACHE_MAX_AGE_DAYS}d)"; cleanup_build_cache; fi
  save_state
}

# -----------------------------------------------------------------------------
# Phase 4: mail
# -----------------------------------------------------------------------------
mime_subject() { printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"; }

send_mail() {   # send_mail SUBJECT BODYFILE
  local subject="$1" body="$2" from="${MAIL_FROM:-docker-housekeeping@$HOSTNAME_FQDN}" rcpt msg transport
  [ -z "$MAIL_TO" ] && { log_warn "MAIL_TO not set, no mail sent"; return 1; }
  transport="$MAIL_TRANSPORT"
  if [ "$transport" = auto ]; then
    if [ -n "$MAIL_SMTP_HOST" ]; then transport=smtp; else transport=sendmail; fi
  fi
  msg=$(mktemp)
  {
    echo "From: $SCRIPT_NAME <$from>"
    # shellcheck disable=SC2086
    echo "To: $(echo $MAIL_TO | sed 's/ /, /g')"
    echo "Subject: $(mime_subject "$subject")"
    echo "Date: $(date -R)"
    echo "Message-ID: <$(date +%s).$$.$SCRIPT_NAME@$HOSTNAME_FQDN>"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo "X-Mailer: $SCRIPT_NAME $VERSION"
    echo
    cat "$body"
  } > "$msg"
  local rc=0 out
  if [ "$transport" = smtp ]; then
    command -v curl >/dev/null || { log_error "curl is required for SMTP delivery"; rm -f "$msg"; return 1; }
    local url args=()
    case "$MAIL_SMTP_TLS" in
      ssl) url="smtps://$MAIL_SMTP_HOST:$MAIL_SMTP_PORT";;
      starttls) url="smtp://$MAIL_SMTP_HOST:$MAIL_SMTP_PORT"; args+=(--ssl-reqd);;
      *) url="smtp://$MAIL_SMTP_HOST:$MAIL_SMTP_PORT";;
    esac
    is_true "$MAIL_SMTP_INSECURE" && args+=(--insecure)
    [ -n "$MAIL_SMTP_USER" ] && args+=(--user "$MAIL_SMTP_USER:$MAIL_SMTP_PASSWORD")
    for rcpt in $MAIL_TO; do args+=(--mail-rcpt "$rcpt"); done
    out=$(curl -sS --max-time 60 --url "$url" --mail-from "$from" "${args[@]}" -T "$msg" 2>&1) || rc=$?
  else
    [ -x "$MAIL_SENDMAIL_BIN" ] || { log_error "$MAIL_SENDMAIL_BIN not available"; rm -f "$msg"; return 1; }
    # shellcheck disable=SC2086
    out=$("$MAIL_SENDMAIL_BIN" -i -f "$from" $MAIL_TO < "$msg" 2>&1) || rc=$?
  fi
  rm -f "$msg"
  if [ $rc -eq 0 ]; then log_info "mail sent to $MAIL_TO ($transport)"; else log_error "mail delivery ($transport) failed: $out"; fi
  return $rc
}

build_report() {   # build_report STATUS -> file name
  local status="$1" f; f=$(mktemp)
  {
    echo "docker-housekeeping report"
    echo "=========================="
    echo "Host      : $HOSTNAME_FQDN"
    echo "Status    : $status"
    echo "Started   : $(date -d @$START_TS '+%Y-%m-%d %H:%M:%S')"
    echo "Duration  : $(( $(date +%s) - START_TS ))s"
    echo "Mode      : $($DRY_RUN && echo DRY-RUN || echo normal)$($EMERGENCY && echo ' EMERGENCY (cooldowns ignored)')"
    echo "Disk      : before $DISK_BEFORE"
    echo "            after  $DISK_AFTER"
    echo "Reclaimed (as reported by docker): $(human_bytes $RECLAIMED_BYTES)"
    echo "Changes: $CHANGES   Warnings: $WARNINGS   Errors: $ERRORS"
    echo
    if [ ${#REPORT_ERRORS[@]} -gt 0 ]; then echo "ERRORS"; echo "------"; printf ' - %s\n' "${REPORT_ERRORS[@]}"; echo; fi
    if [ ${#REPORT_WARNINGS[@]} -gt 0 ]; then echo "Warnings"; echo "--------"; printf ' - %s\n' "${REPORT_WARNINGS[@]}"; echo; fi
    if [ ${#REPORT_CHANGES[@]} -gt 0 ]; then echo "Changes"; echo "-------"; printf ' - %s\n' "${REPORT_CHANGES[@]}"; echo; else echo "No changes."; echo; fi
    echo "docker system df"; echo "----------------"; $DOCKER_BIN system df 2>/dev/null; echo
    if is_true "$MAIL_INCLUDE_LOG"; then
      echo "Log (last $MAIL_LOG_MAX_LINES lines)"; echo "----------------------"
      printf '%s\n' "${LOG_LINES[@]}" | tail -n "$MAIL_LOG_MAX_LINES"
    fi
  } > "$f"
  echo "$f"
}

phase_report() {
  local status="OK" subject body send=false
  [ "$WARNINGS" -gt 0 ] && status="WARN"
  [ "$ERRORS" -gt 0 ] && status="ERROR"
  log_info "=== result: $status (changes=$CHANGES warnings=$WARNINGS errors=$ERRORS, reclaimed $(human_bytes $RECLAIMED_BYTES)) ==="
  $NO_MAIL && return 0
  is_true "$MAIL_ENABLED" || return 0
  if [ "$status" = ERROR ]; then
    is_true "$MAIL_ON_ERROR" && send=true
  elif is_true "$MAIL_ON_SUCCESS"; then
    if is_true "$MAIL_ONLY_ON_CHANGE"; then
      if [ "$CHANGES" -gt 0 ] || [ "$WARNINGS" -gt 0 ]; then send=true; fi
    else
      send=true
    fi
  fi
  $send || { log_info "no mail (status $status, MAIL_ON_SUCCESS=$MAIL_ON_SUCCESS MAIL_ONLY_ON_CHANGE=$MAIL_ONLY_ON_CHANGE)"; return 0; }
  subject="$MAIL_SUBJECT_PREFIX $status $HOSTNAME_FQDN: $CHANGES changes, $ERRORS errors, $(human_bytes $RECLAIMED_BYTES) reclaimed$($DRY_RUN && echo ' (dry-run)')"
  body=$(build_report "$status")
  send_mail "$subject" "$body"
  rm -f "$body"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log_info "===== $SCRIPT_NAME $VERSION started on $HOSTNAME_FQDN$($DRY_RUN && echo ' (DRY-RUN)') ====="
  DISK_BEFORE=$(disk_usage_line)
  log_info "docker root $DOCKER_ROOT: $DISK_BEFORE"

  if $TEST_MAIL; then
    log_info "sending test mail"
    local f rc; f=$(build_report "TEST")
    send_mail "$MAIL_SUBJECT_PREFIX TEST $HOSTNAME_FQDN" "$f"; rc=$?; rm -f "$f"
    finish $rc
  fi

  local c_en="$COMPOSE_ENABLED" w_en="$DOCKERWEB_ENABLED"
  if [ "$c_en" = auto ]; then if [ -d "$COMPOSE_DIR" ]; then c_en=true; else c_en=false; fi; fi
  if [ "$w_en" = auto ]; then if [ -d "$DOCKERWEB_DIR" ]; then w_en=true; else w_en=false; fi; fi

  if is_true "$c_en" && phase_selected compose;            then phase_compose;   else log_info "phase compose skipped"; fi
  if is_true "$w_en" && phase_selected dockerweb;          then phase_dockerweb; else log_info "phase dockerweb skipped"; fi
  if is_true "$CLEANUP_ENABLED" && phase_selected cleanup; then phase_cleanup;   else log_info "phase cleanup skipped"; fi

  DISK_AFTER=$(disk_usage_line)
  log_info "docker root $DOCKER_ROOT: $DISK_AFTER"
  phase_report
  [ "$ERRORS" -gt 0 ] && finish 1
  finish 0
}

main
