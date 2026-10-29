# Service registration for the local backend (kernel :19433, scheduler :28433).
#
# User-level only — no sudo, nothing under /etc or /Library. The real work
# lives in scripts/services.sh (systemd --user on Linux, launchd on macOS).
#
# These targets are never invoked by the test suites or CI: installing a
# long-running service would collide with the tests that spawn their own
# short-lived schedulers.

.PHONY: services-install services-uninstall services-start services-stop \
        services-status services-logs services-dry-run services-dump

services-install:
	@scripts/services.sh install

services-uninstall:
	@scripts/services.sh uninstall

services-start:
	@scripts/services.sh start

services-stop:
	@scripts/services.sh stop

services-status:
	@scripts/services.sh status

services-logs:
	@scripts/services.sh logs

# Show exactly what would be written, without touching systemd/launchd.
services-dry-run:
	@DRY_RUN=1 scripts/services.sh install

# Emit the unit files next to the Makefile for inspection / `systemd-analyze
# verify`. TRHA_DUMP_DIR overrides the destination.
services-dump:
	@scripts/services.sh dump
