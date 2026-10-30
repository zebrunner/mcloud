# Project checks; `make check` runs the linters, the tests of zebrunner.sh and the tests of the services (CONVENTIONS.md)
# the tests of `make docker`, every other tests/*_test.sh is a test of `make test`
# >>> mcloud-conventions
# The shared part of the Makefile of every MCloud repository (CONVENTIONS.md#makefile), synced from mcloud-conventions
SHELL := /bin/bash
VENV := .venv
export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)
.DEFAULT_GOAL := help

help: ## this list
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/'

# The tools of tests/requirements-lint.txt in .venv; the hadolint-py wheel for macOS is broken, brew provides it there
$(VENV)/.installed: tests/requirements-lint.txt
	python3 -m venv $(VENV)
	@if [[ "$$(uname)" == Darwin ]]; then \
	  grep -v '^hadolint-py' tests/requirements-lint.txt > $(VENV)/requirements.txt; \
	else \
	  cp tests/requirements-lint.txt $(VENV)/requirements.txt; \
	fi
	$(VENV)/bin/pip install --quiet --disable-pip-version-check --requirement $(VENV)/requirements.txt
	@command -v hadolint > /dev/null || { echo "hadolint is missing: brew install hadolint"; exit 1; }
	touch $@
# <<< mcloud-conventions

DOCKER_TESTS := tests/compose_test.sh

.PHONY: help check lint test docker

check: ## everything below, as CI runs it; every step runs, the failed ones fail the target
	@status=0; for target in lint test docker; do $(MAKE) --no-print-directory $$target || status=1; done; exit $$status

lint: $(VENV)/.installed ## the linters, the text file checks and docker compose config (tests/lint.sh)
	tests/lint.sh

test: ## every tests/*_test.sh but DOCKER_TESTS: zebrunner.sh with a docker stub, no docker needed
	@status=0; for t in $(filter-out $(DOCKER_TESTS),$(sort $(wildcard tests/*_test.sh))); do $$t || status=1; done; exit $$status

docker: ## DOCKER_TESTS: the services are started and checked; TAG_STF, TAG_SELENIUM_HUB override the image tags
	@status=0; for t in $(DOCKER_TESTS); do $$t || status=1; done; exit $$status
