DOCKER ?= podman

# Порядок совпадает с .pre-commit-config.yaml.
.PHONY: default
default: format-check compile deps-clean xref dialyzer test credo audit

.PHONY: iex
iex:
	iex -S mix

.PHONY: dialyzer
dialyzer:
	mix dialyzer

.PHONY: format
format:
	mix format

# В отличие от `format` — не правит файлы, а падает на неотформатированных.
.PHONY: format-check
format-check:
	mix format --check-formatted

.PHONY: compile
compile:
	mix compile --warnings-as-errors

.PHONY: test
test: infra-up
	mix test

# Тесты, которым нужен живой RabbitMQ Stream (по умолчанию исключены тегом).
.PHONY: test-stream
test-stream: infra-up
	mix test --include rabbit_stream

.PHONY: deps-clean
deps-clean:
	mix deps.clean --unused

.PHONY: credo
credo:
	mix credo --strict

# Известные CVE в зависимостях.
.PHONY: audit
audit:
	mix deps.audit

# Храповик на циклы компиляции: новые добавлять нельзя.
.PHONY: xref
xref:
	mix xref graph --format cycles --fail-above 0

.PHONY: docs
docs:
	mix docs

# ---

.PHONY: infra-up
infra-up:
	$(DOCKER) compose -f deploy/infra/compose.yml up -d --wait

.PHONY: infra-down
infra-down:
	$(DOCKER) compose -f deploy/infra/compose.yml down
