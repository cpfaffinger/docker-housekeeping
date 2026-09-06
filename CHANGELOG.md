# Changelog

## 1.1.6 - 2026-09-06

* `COMPOSE_BUILD_EXCLUDE`: ignore `build:` sections of selected projects and pull their images instead (compose files that still carry a `build:` for a registry image)
* a failed build or pull no longer skips the outdated check of that project
* `HEALTH_TIMEOUT` default raised to 300s; containers whose healthcheck is still `starting` after the timeout produce a warning instead of an error (healthchecks with long intervals, e.g. guacd 5m)

## 1.1.5 - 2026-09-06

* fix: image/volume usage tracking was never persisted (state updated in a subshell), so cooldowns never expired
* fix: build with `BUILDX_NO_DEFAULT_ATTESTATIONS=1` - with the containerd image store the default provenance attestation changed the image ID on every build, which made every instance look outdated and restart daily

## 1.1.4 - 2026-09-06

* script version aligned with the release; installer prints the installed version

## 1.1.3 - 2026-09-06

* installer: fix reading MAIL_FROM from an existing config (1.1.2 shipped this fix incomplete)

## 1.1.1 - 2026-09-06

* installer: `--mail-from` option and sender prompt

## 1.1.0 - 2026-09-06

* installer is interactive when a terminal is available (works with `curl ... | bash`, questions are read from /dev/tty): scheduler, run time, recipients, mail transport
* mail transport choice: local sendmail or external SMTP server with host, port, optional user/password and security none (plain) / starttls / ssl
* every answer available as an option; `--non-interactive` for unattended installs
* optional test mail at the end of the installation
* existing configs are kept; the installer offers to update only the mail settings

## 1.0.0 - 2026-09-06

Initial release.

* compose phase: pull / build projects in `/etc/docker/compose`, restart only when the running image ID differs from the tagged one
* dockerweb phase: build `/home/dockerweb/_template*` images, restart instances that run an outdated image
* cleanup phase: containers, images, volumes, networks, build cache - each with cooldowns based on tracked last usage; emergency mode on full disks
* mail report via SMTP (curl) or local sendmail
* curl-based installer with cron (default) or systemd scheduling, legacy detection and `--disable-legacy`
