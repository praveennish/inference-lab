# One command per stage; every stage writes under build/results/. Run from a Codespace after:
#   source scripts/aws-refresh.sh
SHELL        := /bin/bash
REGION       := ap-southeast-2
ACCOUNT       = $(shell aws sts get-caller-identity --query Account --output text)
STATE_BUCKET  = triage-tfstate-$(ACCOUNT)-$(REGION)
TF_BOOT       = terraform -chdir=infra/bootstrap
TF_SPIKE      = terraform -chdir=infra/spike
BASELINE_DIR ?= build/results/baselines-$(shell date -u +%Y%m%d)
SPIKE_RUN    ?= $(shell cat build/spike_run_id 2>/dev/null)

.PHONY: install check lint test tf-fmt account-checks preflight baseline-rules baseline-claude \
        baselines bootstrap spike test-aws-local spike-plan spike-apply spike-status spike-results spike-down leftovers

install:
	uv sync --all-groups

check: lint test tf-fmt

lint:
	uv run ruff check .
	uv run ruff format --check .

test:
	uv run pytest -q

tf-fmt:
	terraform fmt -check -recursive infra

# ---------------------------------------------------------------- Day 1: no compute
account-checks:
	./scripts/account_checks.sh

preflight:
	./scripts/preflight.sh

baseline-rules:
	uv run python -m bench.classify.run rules --run-dir $(BASELINE_DIR)

# Claude through the Anthropic API; key read from Secrets Manager triage/anthropic-api-key.
baseline-claude:
	uv run python -m bench.classify.run anthropic --model claude-opus-5-5 --run-dir $(BASELINE_DIR)
	uv run python -m bench.classify.run anthropic --model claude-sonnet-5-5 --run-dir $(BASELINE_DIR)

baselines: baseline-rules baseline-claude
	@echo "Paste back: $(BASELINE_DIR)/summary.md"

# ---------------------------------------------------------------- long-lived (cents/month)
bootstrap:
	$(TF_BOOT) init -input=false -reconfigure \
		-backend-config="bucket=$(STATE_BUCKET)" -backend-config="region=$(REGION)"
	$(TF_BOOT) plan -out=boot.tfplan
	@read -p "Apply the plan above? Type yes: " a && [ "$$a" = yes ]
	$(TF_BOOT) apply boot.tfplan

# ---------------------------------------------------------------- Day 1 spike (destroy same day)
# The normal path: preflight, plan, your yes, apply, wait, collect, destroy. One summary file.
spike:
	./scripts/run_spike.sh

# Manual steps, for debugging the spike stack.
BOOT_VARS = -var="boundary_arn=$$($(TF_BOOT) output -raw boundary_arn)" \
            -var="artifacts_bucket=$$($(TF_BOOT) output -raw artifacts_bucket)"

spike-plan:
	@mkdir -p build; [ -s build/spike_run_id ] || date -u +%Y%m%dT%H%M%SZ > build/spike_run_id
	@git rev-parse HEAD > .bundle-commit
	$(TF_SPIKE) init -input=false -reconfigure \
		-backend-config="bucket=$(STATE_BUCKET)" -backend-config="region=$(REGION)"
	$(TF_SPIKE) plan $(BOOT_VARS) -var="run_id=$$(cat build/spike_run_id)" -out=spike.tfplan

spike-apply:
	$(TF_SPIKE) apply spike.tfplan

spike-status:
	@B=$$($(TF_BOOT) output -raw artifacts_bucket); for l in graviton x86; do \
	  echo "--- $$l"; aws s3 cp --quiet "s3://$$B/spike/$(SPIKE_RUN)/$$l/steps.tsv" - 2>/dev/null | column -t; done
	aws ec2 describe-instances --filters Name=tag:stack,Values=spike Name=instance-state-name,Values=pending,running,stopping \
		--query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,State.Name,LaunchTime]' --output text
	-aws eks describe-cluster --name inference-lab-probe --query 'cluster.[name,status,version]' --output text

spike-results:
	aws s3 sync "s3://$$($(TF_BOOT) output -raw artifacts_bucket)/spike/$(SPIKE_RUN)/" \
		build/results/spike-$(SPIKE_RUN)/ --exclude bundle.zip
	cat build/results/spike-$(SPIKE_RUN)/*/spike-summary.md > build/results/spike-$(SPIKE_RUN)/summary.md
	@echo "Paste back: build/results/spike-$(SPIKE_RUN)/summary.md"

spike-down:
	$(TF_SPIKE) destroy $(BOOT_VARS) -var="run_id=$(SPIKE_RUN)"
	$(MAKE) leftovers

# Nightly discipline: anything still alive that carries project=inference-lab.
leftovers:
	@aws resourcegroupstaggingapi get-resources --tag-filters Key=project,Values=inference-lab \
		--query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' \
		| grep -vE ':s3:::|:policy/' || echo "No compute left (bucket and boundary stay by design)."
	@aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
		--query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text

# The real deploy path against a local AWS emulator (moto). No AWS account, no cost.
test-aws-local:
	uv run ./scripts/local_aws/test.sh
