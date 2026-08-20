# Entry points for working with this configuration.
#
# Lint and test targets deliberately use the same flags as the CI pipeline, so a
# clean run here means a clean run there.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TERRAFORM ?= terraform
PYTHON    ?= python3
PATCH_GROUP ?= linux-production

# Relaxed yamllint with the rules that fight published document formatting turned off.
YAMLLINT_CONFIG := {extends: relaxed, rules: {line-length: disable, document-start: disable, truthy: disable, comments-indentation: disable}}
YAML_PATHS      := documents/ automation/ .github/workflows/

.PHONY: help init fmt fmt-check validate lint test plan deploy destroy \
        patch-report compliance-report documents ci clean

help: ## Show the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

init: ## Initialise the working directory without configuring a backend
	$(TERRAFORM) init -backend=false -input=false

fmt: ## Rewrite configuration files into canonical format
	$(TERRAFORM) fmt -recursive

fmt-check: ## Fail if any configuration file is not canonically formatted
	$(TERRAFORM) fmt -check -diff -recursive

validate: fmt-check init ## Format check, initialise, and validate the configuration
	$(TERRAFORM) validate

lint: ## Lint Terraform, document YAML, and Python
	$(TERRAFORM) fmt -check -diff -recursive
	tflint --init
	tflint --minimum-failure-severity=error
	yamllint -d "$(YAMLLINT_CONFIG)" $(YAML_PATHS)
	flake8 --select=E9,F63,F7,F82 --show-source .
	git ls-files '*.py' | xargs -r -n1 $(PYTHON) -m py_compile

test: ## Run the offline document and runbook validation suite
	$(PYTHON) -m pytest tests -q

plan: ## Show the changes an apply would make
	$(TERRAFORM) init -input=false
	$(TERRAFORM) plan

deploy: ## Apply the configuration to the target account and region
	$(TERRAFORM) init -input=false
	$(TERRAFORM) apply

destroy: ## Remove everything this configuration created
	$(TERRAFORM) destroy

documents: ## List the Command documents and Automation runbooks that are published
	@echo "Command documents:"
	@$(TERRAFORM) output -json ssm_document_names | $(PYTHON) -c \
		'import json,sys; [print(f"  {k} -> {v}") for k, v in json.load(sys.stdin).items()]'
	@echo "Automation runbooks:"
	@$(TERRAFORM) output -json automation_runbook_names | $(PYTHON) -c \
		'import json,sys; [print(f"  {k} -> {v}") for k, v in json.load(sys.stdin).items()]'

patch-report: ## Print current patch state for one patch group (PATCH_GROUP=...)
	aws ssm describe-instance-patch-states-for-patch-group \
		--patch-group "$(PATCH_GROUP)" \
		--query 'InstancePatchStates[].[InstanceId,MissingCount,FailedCount,InstalledCount,OperationEndTime]' \
		--output table

compliance-report: ## Invoke the read-only compliance reporter now instead of on its schedule
	aws lambda invoke \
		--function-name "$$($(TERRAFORM) output -raw compliance_report_function_name)" \
		--payload '{}' \
		--cli-binary-format raw-in-base64-out \
		/dev/stdout

ci: lint test validate ## Run every gate the pipeline runs, in pipeline order

clean: ## Remove local Terraform and Python build artefacts
	rm -rf .terraform .terraform.lock.hcl tfplan
	find . -type d -name '__pycache__' -prune -exec rm -rf {} +
	find . -type f -name '*.pyc' -delete
