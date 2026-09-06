# docker-housekeeping

All-in-one, config-driven maintenance for Docker hosts. One script, one config
file, one daily cron job - it replaces the usual pile of `buildAllImages.sh`,
`updateAllComposer.sh`, `docker-cleanup.timer` and `docker system prune -f`
crontab lines that accumulate on servers over time.

Written for hosts that run

* **compose projects** under `/etc/docker/compose/<project>/` managed by a
  `docker-compose@<project>.service` systemd template unit, and/or
* **web instances** under `/home/dockerweb/<instance>/` that all share one
  locally built image (`dockerweb85:1`, `dockerweb84:1`, ...) produced from
  `/home/dockerweb/_template*` and managed by `dockerweb@<instance>.service`,

but every path, unit name and behaviour is configurable.

## What it does

| Phase | What happens |
|-------|--------------|
| **1 compose** | For every project in `COMPOSE_DIR`: `docker compose pull`, `docker compose build --pull` for projects with `build:` sections, then compare the image ID each container is *running* with the image ID its tag *currently points to*. Only projects that really run an outdated image are restarted (`systemctl restart docker-compose@<name>` when that unit is active, otherwise `docker compose up -d`). After a restart the script waits until all containers are running and healthy. |
| **2 dockerweb** | Builds every `_template*` directory (`docker compose build --pull`) and records whether the resulting image ID changed. Then every instance whose container runs an image ID different from the tagged one is restarted (`systemctl restart dockerweb@<name>` or `docker compose up -d --no-build`). Mixed PHP 8.4 / 8.5 templates on one host are handled automatically because the comparison is done per container and per image reference. |
| **3 cleanup** | Removes, each with its own cooldown: stopped containers (stopped for N days), unused images (N days since any container last used them - usage is tracked in a small state file, so "last used" really means last used), unused volumes (optional, named volumes optional), unused networks and build cache. An emergency threshold (disk usage %) ignores all cooldowns when the disk is about to run full. |
| **4 report** | Sends a plain-text report by mail on success and/or error via direct SMTP (curl) or the local `sendmail`. The report contains disk usage before/after, every change, warning and error, `docker system df` and the run log. |

### Why compare image IDs instead of parsing `docker compose pull` output?

The two classic approaches both fail silently:

* grepping for `Pull complete` breaks with newer compose versions (the line no longer exists), so nothing ever restarts;
* comparing `docker compose images -q` before and after a pull compares the images of the *running containers*, which do not change by pulling, so nothing ever restarts either.

Comparing the container's `.Image` with `docker image inspect <ref>` is version independent and also catches containers that were left behind by an earlier failed restart.

## Requirements

* Linux with bash 4+, GNU coreutils, `flock`, `curl`
* Docker Engine with the `docker compose` plugin (v2)
* root (the script restarts systemd units and prunes docker)
* for mail: a local `sendmail` (Postfix/msmtp) or an SMTP server reachable with curl

## Installation

The installer downloads every file with `curl` straight into its destination
(`/usr/local/sbin`, `/etc`, `/etc/cron.d`) - nothing is staged in a temp
directory. Run it as root:

```bash
curl -fsSL https://raw.githubusercontent.com/cpfaffinger/docker-housekeeping/main/install.sh | bash
```

When a terminal is available the installer asks a few questions (answers are
read from `/dev/tty`, so this works through the `curl | bash` pipe):

1. scheduler: `cron` (default, `/etc/cron.d/docker-housekeeping`), `systemd` timer or `none`
2. daily run time (default `04:15`)
3. mail recipients and sender address
4. mail transport:
   * **sendmail** - hand the report to the local MTA (`/usr/sbin/sendmail`, e.g. a Postfix relay)
   * **smtp** - deliver directly to an external SMTP server: host, security
     (`none` = plain SMTP, `starttls`, `ssl`), port (defaults 25 / 587 / 465),
     optional user and password
5. whether legacy automation (`docker-cleanup.timer`, old crontab lines) should be disabled
6. a summary to confirm, and an optional test mail at the end

Every answer can be supplied as an option; `--non-interactive` skips all
questions and uses options or defaults:

```bash
# unattended, local sendmail, disable the old cron lines / docker-cleanup.timer
curl -fsSL https://raw.githubusercontent.com/cpfaffinger/docker-housekeeping/main/install.sh   | bash -s -- --non-interactive --mail-to ops@example.com --disable-legacy

# external SMTP server with STARTTLS and login
curl -fsSL https://raw.githubusercontent.com/cpfaffinger/docker-housekeeping/main/install.sh   | bash -s -- --non-interactive --mail-to ops@example.com        --mail-transport smtp --smtp-host mail.example.com --smtp-port 587        --smtp-tls starttls --smtp-user report --smtp-password 'secret'

# plain SMTP relay without authentication, systemd timer at 03:30
curl -fsSL https://raw.githubusercontent.com/cpfaffinger/docker-housekeeping/main/install.sh   | bash -s -- --non-interactive --mail-to ops@example.com        --mail-transport smtp --smtp-host relay.internal --smtp-port 25 --smtp-tls none        --scheduler systemd --time 03:30

# install a specific tag / branch
curl -fsSL https://raw.githubusercontent.com/cpfaffinger/docker-housekeeping/main/install.sh   | bash -s -- --ref v1.1.0
```

| Option | Meaning |
|--------|---------|
| `--non-interactive` | never ask; use options and defaults |
| `--scheduler cron\|systemd\|none` | daily trigger, default `cron` |
| `--time HH:MM` | daily run time, default `04:15` |
| `--mail-to "A B"` | recipients, space separated |
| `--mail-from ADDR` | sender address (default `docker-housekeeping@<fqdn>`) |
| `--mail-transport sendmail\|smtp` | local MTA or external SMTP server |
| `--smtp-host`, `--smtp-port`, `--smtp-tls none\|starttls\|ssl`, `--smtp-user`, `--smtp-password` | external SMTP settings (plain SMTP is allowed) |
| `--ref REF` | git ref to install, default `main` |
| `--force-config` | overwrite an existing `/etc/docker-housekeeping.conf` |
| `--disable-legacy` | disable `docker-cleanup.timer`, comment out old crontab lines (backup in `/root/crontab.backup-*`) |
| `--no-test-mail` | do not offer a test mail |
| `--uninstall` | remove script, scheduler and logrotate snippet; config, log and state stay |

An existing config is never overwritten (unless `--force-config`); the
installer only offers to update the mail settings inside it.

Installed files:

```
/usr/local/sbin/docker-housekeeping     the script
/etc/docker-housekeeping.conf           configuration
/etc/cron.d/docker-housekeeping         daily trigger (or systemd .service/.timer)
/etc/logrotate.d/docker-housekeeping    log rotation
/var/log/docker-housekeeping.log        log
/var/lib/docker-housekeeping/usage.tsv  last-used tracking for images and volumes
```

Re-running the installer updates the script and keeps the config. Updating
without the installer is a one-liner as well:

```bash
curl -fsSL https://raw.githubusercontent.com/cpfaffinger/docker-housekeeping/main/docker-housekeeping.sh   -o /usr/local/sbin/docker-housekeeping && chmod 755 /usr/local/sbin/docker-housekeeping
```

## First run

```bash
docker-housekeeping --show-config          # effective configuration
docker-housekeeping --dry-run --no-mail    # what would happen, nothing is changed
docker-housekeeping --test-mail            # check mail delivery
docker-housekeeping --phase cleanup        # run a single phase
```

The cleanup phase needs one run to learn which images and volumes are in use
before cooldowns start counting, so the first real run normally removes nothing
that was seen in use before.

## Configuration

`/etc/docker-housekeeping.conf` is a plain `KEY="value"` file sourced by bash.
All keys with their defaults are listed in
[docker-housekeeping.conf.example](docker-housekeeping.conf.example). The most
important ones:

| Key | Default | Purpose |
|-----|---------|---------|
| `COMPOSE_ENABLED` / `DOCKERWEB_ENABLED` | `auto` | run the phase when the directory exists |
| `COMPOSE_EXCLUDE` / `DOCKERWEB_EXCLUDE` | | projects / instances to leave alone (globs) |
| `COMPOSE_RESTART` / `DOCKERWEB_RESTART` | `true` | `false` = only report that a restart is due |
| `COMPOSE_BUILD_EXCLUDE` | | projects whose `build:` sections are ignored; their images are pulled instead |
| `HEALTH_TIMEOUT` | `300` | seconds to wait after a restart; containers whose healthcheck is still `starting` afterwards produce a warning, anything else an error |
| `DOCKERWEB_BUILD_PULL` | `true` | refresh the base image (`php:8.5-apache`) when building templates |
| `DOCKERWEB_RESTART_MAX` | `0` | limit restarts per run (spread big updates over several days) |
| `CLEANUP_CONTAINER_MIN_AGE_DAYS` | `7` | stopped containers are removed after this |
| `CLEANUP_IMAGE_COOLDOWN_DAYS` | `3` | days since an image was last used by any container |
| `CLEANUP_VOLUMES` | `true` | set `false` to never touch volumes |
| `CLEANUP_VOLUMES_NAMED` | `true` | `false` = only anonymous volumes |
| `CLEANUP_VOLUME_COOLDOWN_DAYS` | `14` | days since a volume was last mounted |
| `CLEANUP_*_KEEP_REGEX` | | never remove matching images / volumes |
| `CLEANUP_BUILD_CACHE_MAX_AGE_DAYS` | `7` | prune build cache unused for longer |
| `CLEANUP_EMERGENCY_DISK_PERCENT` | `90` | ignore cooldowns when the docker root is fuller than this |
| `MAIL_TO`, `MAIL_ON_SUCCESS`, `MAIL_ON_ERROR`, `MAIL_ONLY_ON_CHANGE` | | who gets mail and when |
| `MAIL_SMTP_HOST`, `MAIL_SMTP_PORT`, `MAIL_SMTP_TLS`, `MAIL_SMTP_USER`, `MAIL_SMTP_PASSWORD` | | direct SMTP; leave `MAIL_SMTP_HOST` empty to use the local `sendmail` |

## Command line

```
docker-housekeeping [--config FILE] [--dry-run] [--phase compose,dockerweb,cleanup]
                    [--no-mail] [--test-mail] [--verbose] [--show-config] [--version]
```

Exit codes: `0` ok, `1` at least one error (details in log and mail), `2` fatal
(docker not reachable), `3` another instance is running.

## How "last used" tracking works

Docker does not record when an image or volume was last used. The script keeps
`/var/lib/docker-housekeeping/usage.tsv` with, per image ID and volume name, the
time it was first seen and the time it was last seen attached to a container.
An object is a removal candidate when it is not attached to any container
(running *or* stopped) **and** the cooldown has passed since it was last used
(or since it was first seen, for objects that were never used) - and never
before its own creation time plus cooldown. Stopped containers hold their
images and volumes until they are removed themselves after
`CLEANUP_CONTAINER_MIN_AGE_DAYS`.

## Migrating from the old scripts

On each host, after installing:

1. `docker-housekeeping --dry-run --no-mail` and read the output.
2. Remove the old triggers (or let `install.sh --disable-legacy` do it):
   * crontab lines calling `buildAllImages.sh`, `updateAllComposer*.sh`,
     `docker system prune`, `docker image prune`
   * `systemctl disable --now docker-cleanup.timer`
3. Keep unrelated jobs (backups, application crons, health checks).

The old helper scripts can stay on disk; the housekeeping script does not
depend on them.

## License

MIT - see [LICENSE](LICENSE).
