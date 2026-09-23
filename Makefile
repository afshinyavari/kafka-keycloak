CHART := charts/kafka-keycloak-realm

.PHONY: test unit lint realm-tests integration template-dev template-prod

## Everything that runs without Docker.
test: lint unit realm-tests

lint:
	helm lint $(CHART) -f $(CHART)/tests/values/base.yaml

## Kubernetes object shape (helm-unittest plugin).
unit:
	cd $(CHART) && helm unittest .

## Generated realm content (python3 + PyYAML).
realm-tests:
	./test/realm/run.sh

## Applies the rendered realm to a real Keycloak in Docker (~2 min).
integration:
	./test/integration/run.sh

template-dev:
	helm template kc $(CHART) -f examples/values-teams.yaml -f examples/values-dev.yaml

template-prod:
	helm template kc $(CHART) -f examples/values-teams.yaml -f examples/values-prod.yaml
