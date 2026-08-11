## MANET Pi cluster – convenience targets
## Run from the repo root. All ansible commands execute from playbooks/.

PLAYBOOK_DIR := playbooks

# Sources .env (repo root, gitignored - see .env.example) into the recipe's
# shell before anything that reads config from it (ansible-playbook,
# discover.py, docker). `-f` guard means a missing .env is a no-op, not an
# error - group_vars/all.yml's lookup('env', ...) calls fall back to their
# own defaults in that case. Prefixed onto recipes rather than loaded via
# `include` because several values (e.g. SCHEDULER_LOG_WINDOW="2 hours ago")
# contain spaces that Make's own include syntax doesn't quote the way a
# shell `source` does.
WITH_ENV := set -a; [ -f $(CURDIR)/.env ] && . $(CURDIR)/.env; set +a;

ANSIBLE      := $(WITH_ENV) cd $(PLAYBOOK_DIR) && ansible-playbook

# Sibling checkout of the scheduler repo; override if yours lives elsewhere.
SCHEDULER_DIR ?= $(abspath $(CURDIR)/../scheduler)
SCHEDULER_BIN := $(CURDIR)/$(PLAYBOOK_DIR)/files/k8-scheduler

# Pass LIMIT=worker0 to restrict a run to one host.
ifdef LIMIT
  LIMIT_FLAG := --limit $(LIMIT)
endif

# start-logging's session id: the laptop's own clock, computed once here
# rather than left to each node to mint its own on service start (that's
# what used to scatter one experiment across N slightly-different ids - see
# fieldlog_resource.sh). Override to rejoin an existing experiment when
# retrying a node that failed to start, e.g.
#   make start-logging LIMIT=worker7 SESSION=20260807T101616Z
SESSION ?= $(shell date -u +%Y%m%dT%H%M%SZ)

# Pass TAGS=prober or SKIP=prober as needed. Other tags: configure_prompt,
# fetch_kubeconfig, detect_capabilities, gps_hat.
ifdef TAGS
  TAG_FLAG := --tags $(TAGS)
endif
ifdef SKIP
  SKIP_FLAG := --skip-tags $(SKIP)
endif

.PHONY: help discover discover-model ping status identify provision reset reboot kubeconfig kubeconfig-copy deploy label watch registry-trust deploy-scheduler start-logging stop-logging collect-logs known-hosts-reset venividivici-build venividivici-apply venividivici-logs venividivici-delete venividivici-rollout field-phase-one field-phase-two

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m [LIMIT=<host>]\n\nTargets:\n"} \
	     /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2} \
	     /^##/ {printf "\n\033[90m%s\033[0m\n", substr($$0, 4)}' $(MAKEFILE_LIST)

## Discovery

discover: ## List Pis found on the LAN (dry-run, no SSH)
	$(WITH_ENV) cd $(PLAYBOOK_DIR) && python3 inventories/discover.py --list

discover-model: ## List Pis with their Pi model (SSHes into each, manual use only)
	$(WITH_ENV) cd $(PLAYBOOK_DIR) && python3 inventories/discover.py --model

ping: ## Ansible ping all discovered Pis
	cd $(PLAYBOOK_DIR) && ansible all -m ping $(LIMIT_FLAG)

known-hosts-reset: ## ssh-keygen -R every inventory host (run after reflashing/reimaging a Pi)
	shellscripts/reset_known_hosts.sh

status: ## Snapshot apt/dpkg activity on all Pis - tells a slow provision run apart from a stuck one. LIMIT=<host> for one Pi.
	cd $(PLAYBOOK_DIR) && ansible all -b -m shell -a "echo '--- apt/dpkg processes ---'; ps aux | grep -E 'apt|dpkg' | grep -v grep; echo '--- dpkg lock holder (empty = free) ---'; fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>&1 || true" $(LIMIT_FLAG)

identify: ## Blink one Pi's ACT LED for 30s to spot it physically. Usage: make identify LIMIT=worker0
	@if [ -z "$(LIMIT)" ]; then echo "LIMIT=<host> is required, e.g. make identify LIMIT=worker0"; exit 1; fi
	@echo "Blinking $(LIMIT)'s ACT LED for 30s..."
	cd $(PLAYBOOK_DIR) && ansible all -b -m shell -a 'prev=$$(grep -oP "(?<=\[).*?(?=\])" /sys/class/leds/led0/trigger); echo heartbeat > /sys/class/leds/led0/trigger; sleep 30; echo "$$prev" > /sys/class/leds/led0/trigger' $(LIMIT_FLAG)

## Provisioning

provision: ## Provision (or re-verify) the cluster. TAGS/SKIP=prober for just/without the network prober.
	$(ANSIBLE) provision_all.yml $(LIMIT_FLAG) $(TAG_FLAG) $(SKIP_FLAG)

## Automated provisioning (venividivici) - see venividivici/README.md for one-time setup

venividivici-build: ## Build and push the venividivici (in-cluster auto-provisioner) arm64 image
	$(WITH_ENV) docker buildx build --platform linux/arm64 -f venividivici/dockerfile -t "$${REGISTRY_HOST:-manager0.gotham}:$${REGISTRY_PORT:-30500}/venividivici:latest" --push .

venividivici-apply: ## Apply the venividivici deployment (also ensures its hostPath state file exists on manager0)
	cd $(PLAYBOOK_DIR) && ansible manager -b -m ansible.builtin.file -a "path=/var/lib/venividivici state=directory mode=0755"
	cd $(PLAYBOOK_DIR) && ansible manager -b -m ansible.builtin.file -a "path=/var/lib/venividivici/discovered_hosts.json state=touch mode=0644"
	kubectl apply -f venividivici/venividivici.yaml

venividivici-logs: ## Follow the venividivici controller loop
	kubectl logs -f deployment/venividivici

venividivici-delete: ## Delete the venividivici deployment
	kubectl delete -f venividivici/venividivici.yaml

venividivici-rollout: ## Restart venividivici (picks up a new image)
	kubectl rollout restart deployment/venividivici

## Cluster management

kubeconfig: ## Fetch kubeconfig from the manager to ~/.kube/config (kubectl's default)
	($(ANSIBLE) provision_all.yml --limit manager --tags fetch_kubeconfig); \
	mkdir -p $$HOME/.kube; \
	if [ -f $$HOME/.kube/config ]; then cp $$HOME/.kube/config $$HOME/.kube/config.bak; fi; \
	cp $(PLAYBOOK_DIR)/kubeconfig.yml $$HOME/.kube/config; \
	echo "kubeconfig copied to $$HOME/.kube/config"

kubeconfig-copy: ## Copy kubeconfig from manager0 to another Pi's /home/pi/.kube/config. Usage: make kubeconfig-copy HOST=worker0
	@if [ -z "$(HOST)" ]; then echo "HOST=<name> is required, e.g. make kubeconfig-copy HOST=worker0"; exit 1; fi
	$(ANSIBLE) provision_all.yml --limit manager --tags fetch_kubeconfig
	cd $(PLAYBOOK_DIR) && ansible $(HOST) -b -m ansible.builtin.file -a "path=/home/pi/.kube state=directory owner=pi group=pi mode=0700"
	cd $(PLAYBOOK_DIR) && ansible $(HOST) -b -m ansible.builtin.copy -a "src=kubeconfig.yml dest=/home/pi/.kube/config owner=pi group=pi mode=0600"
	@echo "kubeconfig copied to $(HOST):/home/pi/.kube/config"

label: ## Re-detect hardware capabilities and (re)label nodes as k8s node labels. LIMIT=<host> to target one Pi. First-time GPS hardware setup (UART/udev) needs a prior `make provision` (or TAGS=gps_hat) - this target only re-detects/relabels.
	$(ANSIBLE) provision_all.yml --limit manager --tags fetch_kubeconfig
	$(ANSIBLE) provision_all.yml --tags detect_capabilities $(LIMIT_FLAG)

reset: ## Tear down k3s, batman and all provisioning artifacts on all nodes
	@printf '\033[33mThis will uninstall k3s and reset the mesh on ALL nodes. Continue? [y/N] \033[0m'; \
	read ans; [ "$$ans" = y ] || { echo "Aborted."; exit 1; }
	$(ANSIBLE) reset.yml $(LIMIT_FLAG)

reboot: ## Reboot all nodes (or LIMIT=<host> for one)
	@printf '\033[33mThis will reboot ALL nodes. Continue? [y/N] \033[0m'; \
	read ans; [ "$$ans" = y ] || { echo "Aborted."; exit 1; }
	cd $(PLAYBOOK_DIR) && ansible all -b -m reboot $(LIMIT_FLAG)

## Deployments

deploy: ## Pick a k8s deployment (+ action, unless ACTION= is set) and run it. make deploy ACTION=apply|logs|delete|build|rollout
	@shellscripts/deployctl.sh $(ACTION)

deploy-scheduler: ## Build the k8-scheduler binary and deploy it to manager0 (creates the systemd service if missing)
	cd $(SCHEDULER_DIR)/k8_scheduler && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o $(SCHEDULER_BIN) .
	$(ANSIBLE) deploy_scheduler.yml -e scheduler_dir=$(SCHEDULER_DIR)

## Registry

registry-trust: ## Configure THIS machine to push to the Zot registry (fetches the CA from the manager, pins its hostname, trusts it for docker/podman). See registry/README.md.
	$(ANSIBLE) configure_registry_trust_local.yml

## Observability

watch: ## Pick a live cluster view (scheduler logs, ...) and stream it. Ctrl-C to stop.
	@shellscripts/watchctl.sh

# fieldlog-resource.service's RuntimeDirectory=fieldlog (see
# fieldlog_resource.sh) is recreated - wiping any pre-existing contents -
# every time systemd (re)starts the unit, not just when it stops. Seeding
# the session id into /run/fieldlog/session_id *before* `systemctl start`
# used to race that wipe: the marker got clobbered the instant the service
# started, so the script fell back to self-minting its own id from its own
# (possibly clock-drifted) system time instead of the laptop's. Seeding it
# via `systemctl set-environment` instead survives the wipe - it lives in
# the systemd manager's own process, not the filesystem - and the script
# writes whatever id it resolves back into the marker on startup anyway, so
# network_prober.sh's marker-polling keeps working unchanged.
start-logging: ## Sync node clocks, then start field-test resource logging on all nodes (LIMIT=<host> for one; SESSION=<id> to rejoin an existing experiment)
	$(ANSIBLE) sync_time.yml $(LIMIT_FLAG)
	$(WITH_ENV) cd $(PLAYBOOK_DIR) && ansible all -b -m ansible.builtin.command \
		-a "systemctl set-environment FIELDLOG_SESSION_ID=$(SESSION)" $(LIMIT_FLAG)
	$(WITH_ENV) cd $(PLAYBOOK_DIR) && ansible all -b -m ansible.builtin.command -a "systemctl start fieldlog-resource" $(LIMIT_FLAG)
	@echo "session: $(SESSION)"

stop-logging: ## Stop field-test resource logging on all nodes (LIMIT=<host> for one)
	$(WITH_ENV) cd $(PLAYBOOK_DIR) && ansible all -b -m ansible.builtin.command -a "systemctl stop fieldlog-resource" $(LIMIT_FLAG)
	$(WITH_ENV) cd $(PLAYBOOK_DIR) && ansible all -b -m ansible.builtin.command -a "systemctl unset-environment FIELDLOG_SESSION_ID" $(LIMIT_FLAG)

collect-logs: ## Fetch fieldlog CSVs, scheduler journal, and radio-wrapper app pod logs into collected-logs/synced/ (rsync/fetch skip files already present unchanged, so re-running only pulls sessions that aren't on the laptop yet)
	$(ANSIBLE) collect_logs.yml -e collect_dir=$(CURDIR)/collected-logs/synced
	@echo "Logs synced to collected-logs/synced/"

## Experiment (no-router field setup: laptop plugged directly into manager)
#
# Two-phase switchover, see MANAGER_WIRED_IP/WIRED_SCAN_SUBNET in .env.example.
# Phase 1 runs while manager is still reachable on the router/switch LAN, to
# push its static eth0 IP. Phase 2 runs after physically moving the cable and
# giving your own laptop's NIC a static IP in the same subnet - that part
# isn't automatable, it's your machine, not a Pi.

field-phase-one: ## Push manager's static eth0 IP (MANAGER_WIRED_IP) - run BEFORE moving the cable, while still on the router/switch LAN
	@$(WITH_ENV) [ -n "$$MANAGER_WIRED_IP" ] || { echo "MANAGER_WIRED_IP not set in .env - see .env.example"; exit 1; }
	$(ANSIBLE) provision_all.yml --limit manager0

field-phase-two: ## Verify manager0 after the cable swap - run AFTER unplugging the router, plugging laptop into manager, setting laptop's NIC static, and updating WIRED_SCAN_SUBNET in .env
	@$(WITH_ENV) [ -n "$$MANAGER_WIRED_IP" ] || { echo "MANAGER_WIRED_IP not set in .env - see .env.example"; exit 1; }
	$(WITH_ENV) cd $(PLAYBOOK_DIR) && python3 inventories/discover.py --list
	cd $(PLAYBOOK_DIR) && ansible manager0 -m ping
