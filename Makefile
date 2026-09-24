# Day to day commands for the recorded access stack. Run "make" for the list.

PYTHON      ?= python3
TERRAFORM   ?= terraform
COMPOSE     ?= docker compose
ANSIBLE_DIR ?= host-baseline
INVENTORY   ?= inventory/example/hosts.yml
PLAYBOOK    ?= site.yml
LIMIT       ?= all
TAGS        ?= all
MOLECULE_DISTRO ?= rockylinux9
TF_DIRS     := identity pipeline

.DEFAULT_GOAL := help
.PHONY: help yamllint ansible-lint syntax check molecule shellcheck actionlint compose-config fmt tfvars-check tf-validate validate clean context context-check

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-24s %s\n", $$1, $$2}'

yamllint: ## yamllint across the whole repository
	$(PYTHON) -m yamllint -c .yamllint.yaml --strict .

ansible-lint: ## ansible-lint at the production profile over host-baseline/
	cd $(ANSIBLE_DIR) && ansible-lint --offline

syntax: ## ansible-playbook --syntax-check on the host baseline
	cd $(ANSIBLE_DIR) && ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --syntax-check

check: ## Dry run the host baseline (LIMIT=host TAGS=tlog to narrow)
	cd $(ANSIBLE_DIR) && ansible-playbook -i $(INVENTORY) $(PLAYBOOK) --check --diff --limit "$(LIMIT)" --tags "$(TAGS)"

molecule: ## Run the molecule scenario (MOLECULE_DISTRO=rockylinux9|rockylinux8)
	cd $(ANSIBLE_DIR) && MOLECULE_DISTRO=$(MOLECULE_DISTRO) molecule test

shellcheck: ## shellcheck every shell script
	shellcheck $$(find . -name '*.sh' -not -path './.tmp/*' -not -path './.venv/*')

actionlint: ## actionlint every workflow
	actionlint

compose-config: ## Validate the Guacamole compose file with its .env applied
	cd gateways/guacamole && $(COMPOSE) config -q

fmt: ## terraform fmt across every Terraform root
	$(TERRAFORM) fmt -recursive

# Every key in a committed .tfvars.example has to be a variable that exists, and
# every variable with no default has to be in the example, or the documented
# "cp terraform.tfvars.example terraform.tfvars && terraform plan" does not run.
# This is a text check on purpose: "terraform plan -var-file=..." gets as far as
# the same answer and then needs a credential, so it cannot run in CI.
tfvars-check: ## Check each terraform.tfvars.example against its variables.tf
	@status=0; \
	for dir in $(TF_DIRS); do \
		declared=$$(grep -hE '^variable "' $$dir/variables.tf | sed -E 's/^variable "([^"]+)".*/\1/' | sort -u); \
		required=$$(awk '/^variable "/{name=$$2; gsub(/"/,"",name); has=0; next} /^  default[[:space:]]*=/{has=1; next} /^}/{if(name!=""){if(!has) print name; name=""}}' $$dir/variables.tf | sort -u); \
		used=$$(grep -hE '^[a-z_][a-z0-9_]*[[:space:]]*=' $$dir/terraform.tfvars.example | sed -E 's/^([a-z_][a-z0-9_]*).*/\1/' | sort -u); \
		undeclared=$$(printf '%s\n' "$$used" | grep -vxF "$$declared" || true); \
		missing=$$(printf '%s\n' "$$required" | grep -vxF "$$used" || true); \
		[ -z "$$undeclared" ] || { echo "$$dir: set in terraform.tfvars.example, not declared in variables.tf: $$undeclared"; status=1; }; \
		[ -z "$$missing" ] || { echo "$$dir: required variable with no default, missing from terraform.tfvars.example: $$missing"; status=1; }; \
	done; \
	[ $$status -eq 0 ] && echo "tfvars examples ok"; \
	exit $$status

tf-validate: tfvars-check ## terraform init -backend=false and validate for every Terraform root
	@for dir in $(TF_DIRS); do \
		echo "== $$dir"; \
		$(TERRAFORM) -chdir="$$dir" init -backend=false -input=false >/dev/null || exit 1; \
		$(TERRAFORM) -chdir="$$dir" validate || exit 1; \
	done
	$(TERRAFORM) fmt -recursive -check

validate: yamllint ansible-lint syntax shellcheck actionlint tf-validate context-check ## Everything CI runs that needs no Docker and no cloud credential

clean: ## Remove caches and local working directories
	rm -rf .tmp
	rm -rf $(ANSIBLE_DIR)/.collections $(ANSIBLE_DIR)/.facts_cache
	find . -name __pycache__ -type d -prune -exec rm -rf {} +

# Substituted into README.md by "make context". Only these, so every other "$" is left alone.
CONTEXT_VARS := $${CLIENT} $${ENVIRONMENT} $${ENGAGEMENT}

context: ## Render README.md with context.env values into a git-ignored README.local.md
	@command -v envsubst >/dev/null || { echo "envsubst not found. brew install gettext, or apt-get install gettext-base."; exit 1; }
	@test -f context.env || { echo "context.env not found. Copy context.env.example and fill it in."; exit 1; }
	@set -a; . ./context.env; set +a; envsubst '$(CONTEXT_VARS)' < README.md > README.local.md
	@echo "wrote README.local.md (git-ignored)"

context-check: ## Check README tokens and context.env.example variables agree
	@used=$$(awk '/^```/{f=!f; next} !f' README.md | grep -o '$${[A-Z_][A-Z0-9_]*}' | tr -d '$${}' | sort -u); \
	declared=$$(grep -E '^[A-Z_][A-Z0-9_]*=' context.env.example | cut -d= -f1 | sort -u); \
	missing=$$(printf '%s\n' "$$used" | grep -vxF "$$declared" || true); \
	unused=$$(printf '%s\n' "$$declared" | grep -vxF "$$used" || true); \
	status=0; \
	[ -z "$$missing" ] || { echo "in README, not declared: $$missing"; status=1; }; \
	[ -z "$$unused" ] || { echo "declared, not in README: $$unused"; status=1; }; \
	[ $$status -eq 0 ] && echo "context tokens ok"; \
	exit $$status
