#!/usr/bin/env bash
# =============================================================================
# install.sh - install / update / remove docker-housekeeping straight from GitHub
#
# Every file is fetched with curl and written directly to its destination,
# nothing is staged in a temporary directory.
#
#   curl -fsSL https://raw.githubusercontent.com/cpfaffinger/docker-housekeeping/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --scheduler systemd
#   curl -fsSL .../install.sh | bash -s -- --mail-to ops@example.com --disable-legacy
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# Options:
#   --scheduler cron|systemd|none   how to schedule the daily run (default: cron)
#   --time HH:MM                    daily run time (default: 04:15)
#   --mail-to ADDR                  set MAIL_TO in a freshly created config
#   --ref REF                       git ref to install from (default: main)
#   --force-config                  overwrite an existing /etc/docker-housekeeping.conf
#   --disable-legacy                disable docker-cleanup.timer and comment out the old
#                                   crontab lines (buildAllImages.sh, updateAllComposer*.sh,
#                                   docker system/image prune); a crontab backup is kept
#   --uninstall                     remove script, scheduler entries and logrotate snippet
#                                   (config, log and state are kept)
# =============================================================================
set -euo pipefail

REPO="cpfaffinger/docker-housekeeping"
REF="main"
SCHEDULER="cron"
RUN_TIME="04:15"
MAIL_TO=""
FORCE_CONFIG=false
DISABLE_LEGACY=false
UNINSTALL=false

BIN=/usr/local/sbin/docker-housekeeping
CONF=/etc/docker-housekeeping.conf
CRON=/etc/cron.d/docker-housekeeping
UNITDIR=/etc/systemd/system
LOGROTATE=/etc/logrotate.d/docker-housekeeping

while [ $# -gt 0 ]; do
  case "$1" in
    --scheduler) SCHEDULER="$2"; shift;;
    --scheduler=*) SCHEDULER="${1#*=}";;
    --time) RUN_TIME="$2"; shift;;
    --time=*) RUN_TIME="${1#*=}";;
    --mail-to) MAIL_TO="$2"; shift;;
    --mail-to=*) MAIL_TO="${1#*=}";;
    --ref) REF="$2"; shift;;
    --ref=*) REF="${1#*=}";;
    --force-config) FORCE_CONFIG=true;;
    --disable-legacy) DISABLE_LEGACY=true;;
    --uninstall) UNINSTALL=true;;
    -h|--help) sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
  shift
done

BASE="https://raw.githubusercontent.com/$REPO/$REF"
[ "$(id -u)" -eq 0 ] || { echo "please run as root" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

fetch() {  # fetch REMOTE_PATH DEST MODE
  local url="$BASE/$1" dest="$2" mode="$3"
  curl -fsSL "$url" -o "$dest" || { echo "download failed: $url" >&2; exit 1; }
  chmod "$mode" "$dest"
  echo "  installed $dest"
}

if $UNINSTALL; then
  echo "Removing docker-housekeeping ..."
  systemctl disable --now docker-housekeeping.timer 2>/dev/null || true
  rm -f "$CRON" "$UNITDIR/docker-housekeeping.timer" "$UNITDIR/docker-housekeeping.service" "$BIN" "$LOGROTATE"
  systemctl daemon-reload 2>/dev/null || true
  echo "done. Kept: $CONF, /var/log/docker-housekeeping.log, /var/lib/docker-housekeeping"
  exit 0
fi

case "$SCHEDULER" in cron|systemd|none) ;; *) echo "--scheduler must be cron, systemd or none" >&2; exit 1;; esac
[[ "$RUN_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "--time must be HH:MM" >&2; exit 1; }
HH=${RUN_TIME%:*}; MM=${RUN_TIME#*:}

echo "Installing docker-housekeeping from $REPO@$REF"
fetch docker-housekeeping.sh "$BIN" 0755
fetch logrotate.d/docker-housekeeping "$LOGROTATE" 0644

if [ -f "$CONF" ] && ! $FORCE_CONFIG; then
  echo "  kept existing $CONF (use --force-config to overwrite)"
else
  fetch docker-housekeeping.conf.example "$CONF" 0640
  if [ -n "$MAIL_TO" ]; then
    sed -i "s|^MAIL_TO=.*|MAIL_TO=\"$MAIL_TO\"|" "$CONF"
    echo "  MAIL_TO set to $MAIL_TO"
  else
    echo "  NOTE: edit MAIL_TO in $CONF"
  fi
fi

# scheduler: remove whatever the other option left behind, then install the chosen one
systemctl disable --now docker-housekeeping.timer 2>/dev/null || true
rm -f "$CRON" "$UNITDIR/docker-housekeeping.timer" "$UNITDIR/docker-housekeeping.service"
case "$SCHEDULER" in
  cron)
    cat > "$CRON" <<CRONTAB
# docker-housekeeping - daily Docker maintenance (installed from github.com/$REPO)
# The script sends its own report mail, so cron output is discarded.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
$((10#$MM)) $((10#$HH)) * * * root $BIN >/dev/null 2>&1
CRONTAB
    chmod 0644 "$CRON"
    echo "  installed $CRON (daily at $RUN_TIME)"
    ;;
  systemd)
    fetch systemd/docker-housekeeping.service "$UNITDIR/docker-housekeeping.service" 0644
    fetch systemd/docker-housekeeping.timer "$UNITDIR/docker-housekeeping.timer" 0644
    sed -i "s|^OnCalendar=.*|OnCalendar=*-*-* $RUN_TIME:00|" "$UNITDIR/docker-housekeeping.timer"
    systemctl daemon-reload
    systemctl enable --now docker-housekeeping.timer
    echo "  enabled docker-housekeeping.timer (daily at $RUN_TIME)"
    ;;
  none)
    echo "  no scheduler installed"
    ;;
esac
systemctl daemon-reload 2>/dev/null || true

# legacy automation on this host
echo
echo "Legacy automation found on this host:"
LEGACY_RE='buildAllImages\.sh|updateAllComposers?\.sh|docker (system|image) prune'
FOUND=false
if crontab -l 2>/dev/null | grep -nE "^[^#].*($LEGACY_RE)" | sed 's/^/  root crontab line /'; then FOUND=true; fi
if systemctl list-unit-files docker-cleanup.timer --no-legend 2>/dev/null | grep -q docker-cleanup; then
  echo "  systemd docker-cleanup.timer ($(systemctl is-enabled docker-cleanup.timer 2>/dev/null || echo unknown))"; FOUND=true
fi
$FOUND || echo "  none"

if $FOUND && $DISABLE_LEGACY; then
  echo "Disabling legacy automation ..."
  if systemctl list-unit-files docker-cleanup.timer --no-legend 2>/dev/null | grep -q docker-cleanup; then
    systemctl disable --now docker-cleanup.timer 2>/dev/null || true
    echo "  docker-cleanup.timer disabled"
  fi
  if crontab -l 2>/dev/null | grep -qE "^[^#].*($LEGACY_RE)"; then
    backup="/root/crontab.backup-$(date +%Y%m%d-%H%M%S)"
    crontab -l > "$backup"
    crontab -l | sed -E "/^[^#].*($LEGACY_RE)/s/^/#docker-housekeeping# /" | crontab -
    echo "  crontab lines commented out (backup: $backup)"
  fi
elif $FOUND; then
  echo "  (re-run with --disable-legacy to disable them, or do it manually)"
fi

echo
echo "Next steps:"
echo "  $BIN --dry-run --no-mail     # see what would happen"
echo "  $BIN --test-mail             # verify mail delivery"
echo "  $BIN --show-config           # effective configuration"
