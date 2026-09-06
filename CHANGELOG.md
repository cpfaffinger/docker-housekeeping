# Changelog

## 1.0.0 - 2026-09-06

Initial release.

* compose phase: pull / build projects in `/etc/docker/compose`, restart only when the running image ID differs from the tagged one
* dockerweb phase: build `/home/dockerweb/_template*` images, restart instances that run an outdated image
* cleanup phase: containers, images, volumes, networks, build cache - each with cooldowns based on tracked last usage; emergency mode on full disks
* mail report via SMTP (curl) or local sendmail
* curl-based installer with cron (default) or systemd scheduling, legacy detection and `--disable-legacy`
