## MANET Pi cluster – convenience targets
## Run from the repo root. All ansible commands execute from playbooks/.

PLAYBOOK_DIR := playbooks
ANSIBLE      := cd $(PLAYBOOK_DIR) && ansible-playbook

# Pass LIMIT=worker0 to restrict a run to one host.
ifdef LIMIT
  LIMIT_FLAG := --limit $(LIMIT)
endif

# Pass TAGS=prober or SKIP=prober as needed. Other tags: configure_prompt,
# fetch_kubeconfig, detect_capabilities.
ifdef TAGS
  TAG_FLAG := --tags $(TAGS)
endif
ifdef SKIP
  SKIP_FLAG := --skip-tags $(SKIP)
endif

.PHONY: help discover ping status provision reset kubeconfig deploy label watch registry-trust

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m [LIMIT=<host>]\n\nTargets:\n"} \
	     /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2} \
	     /^##/ {printf "\n\033[90m%s\033[0m\n", substr($$0, 4)}' $(MAKEFILE_LIST)

## Discovery

discover: ## List Pis found on the LAN (dry-run, no SSH)
	cd $(PLAYBOOK_DIR) && python3 inventories/discover.py --list

ping: ## Ansible ping all discovered Pis
	cd $(PLAYBOOK_DIR) && ansible all -m ping $(LIMIT_FLAG)

status: ## Snapshot apt/dpkg activity on all Pis - tells a slow provision run apart from a stuck one. LIMIT=<host> for one Pi.
	cd $(PLAYBOOK_DIR) && ansible all -b -m shell -a "echo '--- apt/dpkg processes ---'; ps aux | grep -E 'apt|dpkg' | grep -v grep; echo '--- dpkg lock holder (empty = free) ---'; fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>&1 || true" $(LIMIT_FLAG)

## Provisioning

provision: ## Provision (or re-verify) the cluster. TAGS/SKIP=prober for just/without the network prober.
	$(ANSIBLE) provision_all.yml $(LIMIT_FLAG) $(TAG_FLAG) $(SKIP_FLAG)

## Cluster management

kubeconfig: ## Fetch kubeconfig from the manager to ~/.kube/config (kubectl's default)
	($(ANSIBLE) provision_all.yml --limit manager --tags fetch_kubeconfig); \
	mkdir -p $$HOME/.kube; \
	if [ -f $$HOME/.kube/config ]; then cp $$HOME/.kube/config $$HOME/.kube/config.bak; fi; \
	cp $(PLAYBOOK_DIR)/kubeconfig.yml $$HOME/.kube/config; \
	echo "kubeconfig copied to $$HOME/.kube/config"

label: ## Re-detect hardware capabilities and (re)label nodes as k8s node labels. LIMIT=<host> to target one Pi.
	$(ANSIBLE) provision_all.yml --limit manager --tags fetch_kubeconfig
	$(ANSIBLE) provision_all.yml --tags detect_capabilities $(LIMIT_FLAG)

reset: ## Tear down k3s, batman and all provisioning artifacts on all nodes
	@printf '\033[33mThis will uninstall k3s and reset the mesh on ALL nodes. Continue? [y/N] \033[0m'; \
	read ans; [ "$$ans" = y ] || { echo "Aborted."; exit 1; }
	$(ANSIBLE) reset.yml $(LIMIT_FLAG)

## Deployments

deploy: ## Pick a k8s deployment (+ action, unless ACTION= is set) and run it. make deploy ACTION=apply|logs|delete|build|rollout
	@shellscripts/deployctl.sh $(ACTION)

## Registry

registry-trust: ## Configure THIS machine to push to the Zot registry (fetches the CA from the manager, pins its hostname, trusts it for docker/podman). See registry/README.md.
	$(ANSIBLE) configure_registry_trust_local.yml

## Observability

watch: ## Pick a live cluster view (scheduler logs, ...) and stream it. Ctrl-C to stop.
	@shellscripts/watchctl.sh
