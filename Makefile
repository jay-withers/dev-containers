.DEFAULT_GOAL := help

.PHONY: help setup lint build build-base build-terraform build-k8s protect-branch

BRANCH ?= main
CHECKS ?= pre-commit / Pre-commit

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

setup: ## Install the pre-commit git hooks
	pre-commit install

lint: ## Run all pre-commit hooks against every file
	pre-commit run --all-files

build: build-base build-terraform build-k8s ## Build all images locally

build-base: ## Build the base image
	docker build -t base images/base

build-terraform: build-base ## Build the terraform image (FROM base)
	docker build --build-arg BASE_IMAGE=base -t terraform images/terraform

build-k8s: build-base ## Build the k8s image (FROM base)
	docker build --build-arg BASE_IMAGE=base -t k8s images/k8s

protect-branch: ## Configure repo auto-merge + branch protection ruleset via gh (args: BRANCH, CHECKS)
	./scripts/protect-branch.sh "$(BRANCH)" "$(CHECKS)"
