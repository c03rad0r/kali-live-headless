SHELL := /bin/bash

REPO := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
INVENTORY := $(REPO)/inventory/localhost.yml
PLAYBOOK := $(REPO)/playbooks/ventoy.yml
ANSIBLE_PLAYBOOK ?= ansible-playbook
BECOME_FLAG ?= -K
EXTRA ?=
ALLOW_LOOP ?= false
ALLOW_LARGE_USB ?= false
RESERVE_MIB ?= 0

AP := $(ANSIBLE_PLAYBOOK) -i $(INVENTORY) $(PLAYBOOK)
COMMON := -e ventoy_device="$(USB)" -e ventoy_confirm="$(CONFIRM)" \
          -e ventoy_serial="$(SERIAL)" \
          -e ventoy_allow_loop="$(ALLOW_LOOP)" \
          -e ventoy_allow_large_usb="$(ALLOW_LARGE_USB)" \
          -e ventoy_reserve_mib="$(RESERVE_MIB)" $(EXTRA)

USB ?=
CONFIRM ?=
SERIAL ?=

.PHONY: help usb-list ventoy-plan ventoy-isos ventoy-install ventoy-update \
        ventoy-sync ventoy-verify ventoy-all ventoy-archive-logs \
        ventoy-test-loop ventoy-lint

help:
	@printf '%s\n' \
	  'Ventoy multiboot targets:' \
	  '' \
	  '  make usb-list' \
	  '  make ventoy-plan USB=/dev/sdX' \
	  '  make ventoy-isos' \
	  '  make ventoy-install USB=/dev/sdX CONFIRM=yes' \
	  '  make ventoy-sync USB=/dev/sdX CONFIRM=yes' \
	  '  make ventoy-verify USB=/dev/sdX' \
	  '  make ventoy-all USB=/dev/sdX CONFIRM=yes' \
	  '  make ventoy-update USB=/dev/sdX CONFIRM=yes' \
	  '  make ventoy-archive-logs' \
	  '  make ventoy-test-loop' \
	  '  make ventoy-lint' \
	  '' \
	  'Destructive targets require CONFIRM=yes. If SERIAL is omitted, the' \
	  'role prompts and compares the typed value with the device serial.'

usb-list:
	@python3 "$(REPO)/scripts/usb-list.py"

ventoy-plan:
	@test -n "$(USB)" || { echo "usage: make ventoy-plan USB=/dev/sdX" >&2; exit 1; }
	@$(AP) --tags plan $(COMMON)

ventoy-isos:
	@$(AP) --tags isos $(EXTRA)

ventoy-install:
	@test -n "$(USB)" || { echo "usage: make ventoy-install USB=/dev/sdX CONFIRM=yes" >&2; exit 1; }
	@test "$(CONFIRM)" = yes || { echo "pass CONFIRM=yes" >&2; exit 1; }
	@$(AP) $(BECOME_FLAG) --tags install $(COMMON)

ventoy-update:
	@test -n "$(USB)" || { echo "usage: make ventoy-update USB=/dev/sdX CONFIRM=yes" >&2; exit 1; }
	@test "$(CONFIRM)" = yes || { echo "pass CONFIRM=yes" >&2; exit 1; }
	@$(AP) $(BECOME_FLAG) --tags update $(COMMON)

ventoy-sync:
	@test -n "$(USB)" || { echo "usage: make ventoy-sync USB=/dev/sdX CONFIRM=yes" >&2; exit 1; }
	@test "$(CONFIRM)" = yes || { echo "pass CONFIRM=yes" >&2; exit 1; }
	@$(AP) $(BECOME_FLAG) --tags config $(COMMON)

ventoy-verify:
	@test -n "$(USB)" || { echo "usage: make ventoy-verify USB=/dev/sdX" >&2; exit 1; }
	@$(AP) $(BECOME_FLAG) --tags verify $(COMMON)

ventoy-all:
	@test -n "$(USB)" || { echo "usage: make ventoy-all USB=/dev/sdX CONFIRM=yes" >&2; exit 1; }
	@test "$(CONFIRM)" = yes || { echo "pass CONFIRM=yes" >&2; exit 1; }
	@$(AP) $(BECOME_FLAG) --tags plan,install,isos,config,verify $(COMMON)

ventoy-archive-logs:
	@"$(REPO)/scripts/ventoy-archive-logs.sh"

ventoy-test-loop:
	@"$(REPO)/scripts/ventoy-test-loop.sh"

ventoy-lint:
	@python3 -m py_compile "$(REPO)/scripts/usb-list.py"
	@bash -n "$(REPO)"/scripts/*.sh
	@shellcheck -S warning "$(REPO)"/scripts/*.sh
	@yamllint -c "$(REPO)/.yamllint.yml" \
	  "$(REPO)/inventory" "$(REPO)/playbooks" "$(REPO)/roles" "$(REPO)/ventoy"
	@$(AP) --syntax-check
	@if command -v ansible-lint >/dev/null 2>&1; then \
	  ansible-lint "$(REPO)/playbooks/ventoy.yml"; \
	else \
	  echo "ansible-lint not installed; skipped"; \
	fi
