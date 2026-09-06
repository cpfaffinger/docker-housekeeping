#!/usr/bin/env bash
# =============================================================================
# install.sh - install / update / remove docker-housekeeping straight from GitHub
#
# Every file is fetched with curl and written directly to its destination,
# nothing is staged in a temporary directory. When a terminal is available the
# installer asks interactively (scheduler, run time, recipients, mail
# transport); every answer can also be given as an option, and
# --non-interactive skips all questions.
#
#   curl -fsSL https://raw.githubusercontent.com/cpfaffinger/docker-housekeeping/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --non-interactive --mail-to ops@example.com --disable-legacy
#   curl -fsSL .../install.sh | bash -s -- --mail-transport smtp --smtp-host mail.example.com \
#                                          --smtp-port 587 --smtp-tls starttls --smtp-user u --smtp-password p
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# Options:
#   --non-interactive               never ask, use options / defaults
#   --scheduler cron|systemd|none   daily trigger (default: cron)
#   --time HH:MM                    daily run time (default: 04:15)
#   --mail-to "A B"                 recipients (space separated)
#   --mail-from ADDR                sender address (default: docker-housekeeping@<fqdn>)
#   --mail-transport sendmail|smtp  local sendmail (Postfix/msmtp) or external SMTP server
#   --smtp-host HOST                external SMTP server
#   --smtp-port PORT                default 25 (none), 587 (starttls), 465 (ssl)
#   --smtp-tls none|starttls|ssl    transport security (plain is allowed)
#   --smtp-user USER                optional SMTP login
#   --smtp-password PASS            optional SMTP password
#   --ref REF                       git ref to install from (default: main)
#   --force-config                  overwrite an existing /etc/docker-housekeeping.conf
#   --disable-legacy                disable docker-cleanup.timer and comment out the old
#                                   crontab lines (buildAllImages.sh, updateAllComposer*.sh,
#                                   docker system/image prune); a crontab backup is kept
#   --no-test-mail                  do not offer / send a test mail at the end
#   --uninstall                     remove script, scheduler entries and logrotate snippet
#                                   (config, log and state are kept)
# =============================================================================
set -euo pipefail

REPO="cpfaffinger/docker-housekeeping"
REF="main"
SCHEDULER=""
RUN_TIME=""
MAIL_TO=""
MAIL_FROM=""
MAIL_TRANSPORT=""
SMTP_HOST=""
SMTP_PORT=""
SMTP_TLS=""
SMTP_USER=""
SMTP_PASSWORD=""
FORCE_CONFIG=false
DISABLE_LEGACY=""
TEST_MAIL=""
UNINSTALL=false
INTERACTIVE=true

BIN=/usr/local/sbin/docker-housekeeping
CONF=/etc/docker-housekeeping.conf
CRON=/etc/cron.d/docker-housekeeping
UNITDIR=/etc/systemd/system
LOGROTATE=/etc/logrotate.d/docker-housekeeping

while [ $# -gt 0 ]; do
  case "$1" in
    --non-interactive|--yes|-y) INTERACTIVE=false;;
    --scheduler) SCHEDULER="$2"; shift;;         --scheduler=*) SCHEDULER="${1#*=}";;
    --time) RUN_TIME="$2"; shift;;               --time=*) RUN_TIME="${1#*=}";;
    --mail-to) MAIL_TO="$2"; shift;;             --mail-to=*) MAIL_TO="${1#*=}";;
    --mail-from) MAIL_FROM="$2"; shift;;         --mail-from=*) MAIL_FROM="${1#*=}";;
    --mail-transport) MAIL_TRANSPORT="$2"; shift;; --mail-transport=*) MAIL_TRANSPORT="${1#*=}";;
    --smtp-host) SMTP_HOST="$2"; shift;;         --smtp-host=*) SMTP_HOST="${1#*=}";;
    --smtp-port) SMTP_PORT="$2"; shift;;         --smtp-port=*) SMTP_PORT="${1#*=}";;
    --smtp-tls) SMTP_TLS="$2"; shift;;           --smtp-tls=*) SMTP_TLS="${1#*=}";;
    --smtp-user) SMTP_USER="$2"; shift;;         --smtp-user=*) SMTP_USER="${1#*=}";;
    --smtp-password) SMTP_PASSWORD="$2"; shift;; --smtp-password=*) SMTP_PASSWORD="${1#*=}";;
    --ref) REF="$2"; shift;;                     --ref=*) REF="${1#*=}";;
    --force-config) FORCE_CONFIG=true;;
    --disable-legacy) DISABLE_LEGACY=true;;
    --no-test-mail) TEST_MAIL=false;;
    --uninstall) UNINSTALL=true;;
    -h|--help) sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
  shift
done

BASE="https://raw.githubusercontent.com/$REPO/$REF"
[ "$(id -u)" -eq 0 ] || { echo "please run as root" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }

# a terminal for questions - stdin is the curl pipe, so read from /dev/tty
TTY=/dev/tty
if $INTERACTIVE && ! { [ -r "$TTY" ] && [ -w "$TTY" ] && (: < "$TTY") 2>/dev/null; }; then
  INTERACTIVE=false
fi

say()  { echo "$@"; }
ask()  {   # ask VAR "prompt" "default" [secret]
  local __var="$1" prompt="$2" def="${3:-}" secret="${4:-}" val
  if ! $INTERACTIVE; then printf -v "$__var" '%s' "$def"; return; fi
  if [ -n "$secret" ]; then
    read -r -s -p "$prompt${def:+ [******]}: " val < "$TTY"; echo > "$TTY"
  else
    read -r -p "$prompt${def:+ [$def]}: " val < "$TTY"
  fi
  printf -v "$__var" '%s' "${val:-$def}"
}
ask_yn() {  # ask_yn "prompt" default(y|n) -> 0 = yes
  local prompt="$1" def="$2" val
  if ! $INTERACTIVE; then [ "$def" = y ]; return; fi
  while :; do
    read -r -p "$prompt [$([ "$def" = y ] && echo Y/n || echo y/N)]: " val < "$TTY"
    val="${val:-$def}"
    case "${val,,}" in y|yes) return 0;; n|no) return 1;; esac
  done
}
ask_choice() {  # ask_choice VAR "prompt" default "opt1 opt2 ..."
  local __var="$1" prompt="$2" def="$3" opts="$4" val o
  if ! $INTERACTIVE; then printf -v "$__var" '%s' "$def"; return; fi
  while :; do
    read -r -p "$prompt ($(echo "$opts" | tr ' ' '/')) [$def]: " val < "$TTY"
    val="${val:-$def}"
    for o in $opts; do [ "$val" = "$o" ] && { printf -v "$__var" '%s' "$val"; return; }; done
    say "  please answer one of: $opts" > "$TTY"
  done
}

fetch() {  # fetch REMOTE_PATH DEST MODE
  local url="$BASE/$1" dest="$2" mode="$3"
  curl -fsSL "$url" -o "$dest" || { echo "download failed: $url" >&2; exit 1; }
  chmod "$mode" "$dest"
  say "  installed $dest"
}

set_conf() {  # set_conf KEY VALUE  (replace or append in $CONF)
  local key="$1" val="$2" esc
  esc=$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')
  if grep -qE "^$key=" "$CONF"; then
    sed -i "s|^$key=.*|$key=\"$esc\"|" "$CONF"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$CONF"
  fi
}

# -----------------------------------------------------------------------------
# uninstall
# -----------------------------------------------------------------------------
if $UNINSTALL; then
  say "Removing docker-housekeeping ..."
  systemctl disable --now docker-housekeeping.timer 2>/dev/null || true
  rm -f "$CRON" "$UNITDIR/docker-housekeeping.timer" "$UNITDIR/docker-housekeeping.service" "$BIN" "$LOGROTATE"
  systemctl daemon-reload 2>/dev/null || true
  say "done. Kept: $CONF, /var/log/docker-housekeeping.log, /var/lib/docker-housekeeping"
  exit 0
fi

# -----------------------------------------------------------------------------
# questions
# -----------------------------------------------------------------------------
say "docker-housekeeping installer ($REPO@$REF)"
$INTERACTIVE && say "Press Enter to accept the default shown in [brackets]."
say

CONFIG_EXISTS=false; [ -f "$CONF" ] && CONFIG_EXISTS=true
WRITE_MAIL=true
if $CONFIG_EXISTS && ! $FORCE_CONFIG; then
  say "Existing config found: $CONF (kept)"
  if ask_yn "Update the mail settings inside the existing config?" n; then WRITE_MAIL=true; else WRITE_MAIL=false; fi
fi

[ -z "$SCHEDULER" ] && ask_choice SCHEDULER "Scheduler" cron "cron systemd none"
case "$SCHEDULER" in cron|systemd|none) ;; *) echo "--scheduler must be cron, systemd or none" >&2; exit 1;; esac
if [ "$SCHEDULER" != none ]; then
  while :; do
    [ -z "$RUN_TIME" ] && ask RUN_TIME "Daily run time (HH:MM)" "04:15"
    [[ "$RUN_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
    say "  invalid time: $RUN_TIME"; RUN_TIME=""; $INTERACTIVE || exit 1
  done
fi

if $WRITE_MAIL; then
  CUR_TO=""; $CONFIG_EXISTS && CUR_TO=$(sed -n 's/^MAIL_TO="\(.*\)"/\1/p' "$CONF" | head -1)
  [ -z "$MAIL_TO" ] && ask MAIL_TO "Mail recipient(s), space separated" "${CUR_TO:-root@$(hostname -f 2>/dev/null || hostname)}"
  CUR_FROM=""; $CONFIG_EXISTS && CUR_FROM=$(sed -n 's/^MAIL_FROM="\(.*\)"/\1/p' "$CONF" | head -1)
  [ -z "$MAIL_FROM" ] && ask MAIL_FROM "Sender address (empty = docker-housekeeping@$(hostname -f 2>/dev/null || hostname))" "$CUR_FROM"
  if [ -z "$MAIL_TRANSPORT" ]; then
    if [ -n "$SMTP_HOST" ]; then MAIL_TRANSPORT=smtp
    else
      say
      say "Mail transport:"
      say "  sendmail - hand the report to the local MTA (/usr/sbin/sendmail, e.g. Postfix relay)"
      say "  smtp     - deliver directly to an external SMTP server (host, port, optional login, plain or TLS)"
      def=sendmail; [ -x /usr/sbin/sendmail ] || def=smtp
      ask_choice MAIL_TRANSPORT "Transport" "$def" "sendmail smtp"
    fi
  fi
  case "$MAIL_TRANSPORT" in sendmail|smtp) ;; *) echo "--mail-transport must be sendmail or smtp" >&2; exit 1;; esac
  if [ "$MAIL_TRANSPORT" = smtp ]; then
    while [ -z "$SMTP_HOST" ]; do ask SMTP_HOST "SMTP host" ""; [ -z "$SMTP_HOST" ] && { $INTERACTIVE || { echo "--smtp-host required" >&2; exit 1; }; }; done
    [ -z "$SMTP_TLS" ] && ask_choice SMTP_TLS "Security (none = plain SMTP)" none "none starttls ssl"
    case "$SMTP_TLS" in none|starttls|ssl) ;; *) echo "--smtp-tls must be none, starttls or ssl" >&2; exit 1;; esac
    case "$SMTP_TLS" in ssl) defport=465;; starttls) defport=587;; *) defport=25;; esac
    [ -z "$SMTP_PORT" ] && ask SMTP_PORT "SMTP port" "$defport"
    [[ "$SMTP_PORT" =~ ^[0-9]+$ ]] || { echo "invalid port: $SMTP_PORT" >&2; exit 1; }
    [ -z "$SMTP_USER" ] && ask SMTP_USER "SMTP user (empty = no authentication)" ""
    if [ -n "$SMTP_USER" ] && [ -z "$SMTP_PASSWORD" ]; then ask SMTP_PASSWORD "SMTP password" "" secret; fi
  fi
fi

if [ -z "$DISABLE_LEGACY" ]; then
  if ask_yn "Disable legacy automation (docker-cleanup.timer, old crontab lines) if found?" n; then DISABLE_LEGACY=true; else DISABLE_LEGACY=false; fi
fi

say
say "Summary:"
say "  scheduler      : $SCHEDULER${RUN_TIME:+ at $RUN_TIME}"
if $WRITE_MAIL; then
  say "  mail to        : $MAIL_TO"
  say "  mail from      : ${MAIL_FROM:-docker-housekeeping@$(hostname -f 2>/dev/null || hostname)}"
  say "  mail transport : $MAIL_TRANSPORT${SMTP_HOST:+ -> $SMTP_HOST:$SMTP_PORT ($SMTP_TLS${SMTP_USER:+, user $SMTP_USER})}"
else
  say "  mail           : unchanged ($CONF)"
fi
say "  config         : $($CONFIG_EXISTS && ! $FORCE_CONFIG && echo "keep existing" || echo "create from example")"
say "  disable legacy : $DISABLE_LEGACY"
ask_yn "Proceed?" y || { say "aborted"; exit 1; }
say

# -----------------------------------------------------------------------------
# install files
# -----------------------------------------------------------------------------
say "Installing files"
fetch docker-housekeeping.sh "$BIN" 0755
fetch logrotate.d/docker-housekeeping "$LOGROTATE" 0644
if $CONFIG_EXISTS && ! $FORCE_CONFIG; then
  say "  kept $CONF"
else
  fetch docker-housekeeping.conf.example "$CONF" 0640
fi
if $WRITE_MAIL; then
  set_conf MAIL_TO "$MAIL_TO"
  set_conf MAIL_FROM "$MAIL_FROM"
  set_conf MAIL_TRANSPORT "$MAIL_TRANSPORT"
  if [ "$MAIL_TRANSPORT" = smtp ]; then
    set_conf MAIL_SMTP_HOST "$SMTP_HOST"
    set_conf MAIL_SMTP_PORT "$SMTP_PORT"
    set_conf MAIL_SMTP_TLS "$SMTP_TLS"
    set_conf MAIL_SMTP_USER "$SMTP_USER"
    set_conf MAIL_SMTP_PASSWORD "$SMTP_PASSWORD"
  else
    set_conf MAIL_SMTP_HOST ""
  fi
  chmod 0640 "$CONF"
  say "  mail settings written to $CONF"
fi

# scheduler: remove whatever the other option left behind, then install the chosen one
systemctl disable --now docker-housekeeping.timer 2>/dev/null || true
rm -f "$CRON" "$UNITDIR/docker-housekeeping.timer" "$UNITDIR/docker-housekeeping.service"
case "$SCHEDULER" in
  cron)
    HH=${RUN_TIME%:*}; MM=${RUN_TIME#*:}
    cat > "$CRON" <<CRONTAB
# docker-housekeeping - daily Docker maintenance (installed from github.com/$REPO)
# The script sends its own report mail, so cron output is discarded.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
$((10#$MM)) $((10#$HH)) * * * root $BIN >/dev/null 2>&1
CRONTAB
    chmod 0644 "$CRON"
    say "  installed $CRON (daily at $RUN_TIME)"
    ;;
  systemd)
    fetch systemd/docker-housekeeping.service "$UNITDIR/docker-housekeeping.service" 0644
    fetch systemd/docker-housekeeping.timer "$UNITDIR/docker-housekeeping.timer" 0644
    sed -i "s|^OnCalendar=.*|OnCalendar=*-*-* $RUN_TIME:00|" "$UNITDIR/docker-housekeeping.timer"
    systemctl daemon-reload
    systemctl enable --now docker-housekeeping.timer
    say "  enabled docker-housekeeping.timer (daily at $RUN_TIME)"
    ;;
  none)
    say "  no scheduler installed"
    ;;
esac
systemctl daemon-reload 2>/dev/null || true

# -----------------------------------------------------------------------------
# legacy automation
# -----------------------------------------------------------------------------
say
say "Legacy automation on this host:"
LEGACY_RE='buildAllImages\.sh|updateAllComposers?\.sh|docker (system|image) prune'
FOUND=false
if crontab -l 2>/dev/null | grep -nE "^[^#].*($LEGACY_RE)" | sed 's/^/  root crontab line /'; then FOUND=true; fi
if systemctl list-unit-files docker-cleanup.timer --no-legend 2>/dev/null | grep -q docker-cleanup; then
  say "  systemd docker-cleanup.timer ($(systemctl is-enabled docker-cleanup.timer 2>/dev/null || echo unknown))"; FOUND=true
fi
$FOUND || say "  none"

if $FOUND && [ "$DISABLE_LEGACY" = true ]; then
  say "Disabling legacy automation ..."
  if systemctl list-unit-files docker-cleanup.timer --no-legend 2>/dev/null | grep -q docker-cleanup; then
    systemctl disable --now docker-cleanup.timer 2>/dev/null || true
    say "  docker-cleanup.timer disabled"
  fi
  if crontab -l 2>/dev/null | grep -qE "^[^#].*($LEGACY_RE)"; then
    backup="/root/crontab.backup-$(date +%Y%m%d-%H%M%S)"
    crontab -l > "$backup"
    crontab -l | sed -E "/^[^#].*($LEGACY_RE)/s/^/#docker-housekeeping# /" | crontab -
    say "  crontab lines commented out (backup: $backup)"
  fi
elif $FOUND; then
  say "  (re-run with --disable-legacy to disable them, or do it manually)"
fi

# -----------------------------------------------------------------------------
# test mail
# -----------------------------------------------------------------------------
say
if [ "$TEST_MAIL" != false ] && $WRITE_MAIL; then
  if ask_yn "Send a test mail now?" y; then
    "$BIN" --test-mail || say "  test mail FAILED - check $CONF and /var/log/docker-housekeeping.log"
  fi
fi

say
say "Installed: $("$BIN" --version 2>/dev/null || echo "$BIN")"
say "Next steps:"
say "  $BIN --dry-run --no-mail     # see what would happen"
say "  $BIN --test-mail             # verify mail delivery"
say "  $BIN --show-config           # effective configuration"
