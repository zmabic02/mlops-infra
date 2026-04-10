# =============================================================================
# Makefile for infra repo
# =============================================================================

.PHONY: help install-argocd-cli argocd-login add-argocd-repo bootstrap validate validate-kubeflow apply-all apply-root port-forward clean restart-argocd

GREEN  := \033[0;32m
YELLOW := \033[0;33m
RESET  := \033[0m

ARGOCD_NAMESPACE ?= argocd
ARGOCD_SERVER ?= localhost:8080
ARGOCD_OPTS ?= --grpc-web --insecure
ARGOCD_REPO_URL ?= https://github.com/zmabic02/mlops-infra.git
ARGOCD_REPO_SECRET_NAME ?= repo-mlops-infra

help: ## Show available commands
	@echo "========================================"
	@echo "  Available commands:"
	@echo "========================================"
	@awk 'BEGIN {FS = ":.*##"; printf "\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  ${GREEN}%-25s${RESET} %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# Automatska instalacija argocd CLI (Linux x86_64)
install-argocd-cli:
	@command -v argocd >/dev/null 2>&1 && echo "argocd CLI already installed" || ( \
		echo "Installing ArgoCD CLI..."; \
		tmp_file=$$(mktemp); \
		LATEST=$$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep '"tag_name"' | cut -d '"' -f 4); \
		curl -fsSL -o $$tmp_file "https://github.com/argoproj/argo-cd/releases/download/$${LATEST}/argocd-linux-amd64"; \
		sudo install -m 0755 $$tmp_file /usr/local/bin/argocd; \
		rm -f $$tmp_file; \
		echo "ArgoCD CLI installed"; \
	)


argocd-login: install-argocd-cli ## Login to ArgoCD CLI (run make port-forward in another terminal first)
	@ADMIN_PASSWORD=$$(kubectl -n $(ARGOCD_NAMESPACE) get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d); \
	argocd login $(ARGOCD_SERVER) --username admin --password "$$ADMIN_PASSWORD" $(ARGOCD_OPTS)


add-argocd-repo: ## Register private GitHub repo in ArgoCD using a Kubernetes Secret and .env credentials
	@if [ ! -f .env ]; then echo ".env file not found!" && exit 1; fi; \
	set -a && . ./.env && set +a && \
	printf '%s\n' \
	  'apiVersion: v1' \
	  'kind: Secret' \
	  'metadata:' \
	  '  name: $(ARGOCD_REPO_SECRET_NAME)' \
	  '  namespace: $(ARGOCD_NAMESPACE)' \
	  '  labels:' \
	  '    argocd.argoproj.io/secret-type: repository' \
	  'stringData:' \
	  '  type: git' \
	  '  url: $(ARGOCD_REPO_URL)' \
	  "  username: $$GITHUB_USER" \
	  "  password: $$GITHUB_TOKEN" | kubectl apply -f - && \
	echo "${GREEN}ArgoCD repository secret applied${RESET}"
	

bootstrap: install-argocd-cli ## Initial installation (k3s + ArgoCD)
	@echo "${YELLOW}Starting bootstrap...${RESET}"
	./bootstrap/k3s-install.sh
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd \
		--server-side \
		--force-conflicts \
		-f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	@echo "${GREEN}ArgoCD installed"

clean: ## Delete entire k3s cluster and kubeconfig
	@echo "${YELLOW}Cleanup started"
	./bootstrap/k3s-uninstall.sh
	@echo "${GREEN}Cleanup complete"


validate: ## Validate all manifests (kustomize + kubeconform)
	@echo "${YELLOW}Validating manifests...${RESET}"
	kustomize build kubeflow/overlays/k3s >/dev/null
	kustomize build argocd/applications/ | kubeconform --summary -strict
	@echo "${GREEN}Validation successful${RESET}"


validate-kubeflow: ## Validate Kubeflow kustomization render
	kustomize build kubeflow/overlays/k3s >/dev/null
	@echo "${GREEN}Kubeflow render successful${RESET}"


apply-root: ## Apply only root App-of-Apps
	@echo "${YELLOW}Applying root App-of-Apps...${RESET}"
	kustomize build argocd/applications/ | kubectl apply -f -
	@echo "${GREEN}Done${RESET}"

apply-all: validate apply-root ## Validate + apply all

port-forward: ## Port-forward for ArgoCD UI to http://localhost:8080
	kubectl port-forward -n argocd svc/argocd-server 8080:80

kubeflow-dash: ## Port-forward Kubeflow dashboard to http://localhost:8081
	kubectl port-forward -n istio-system svc/istio-ingressgateway 8081:80

restart-argocd: ## Restart ArgoCD controller
	kubectl rollout restart deployment argocd-application-controller -n argocd
	kubectl rollout restart deployment argocd-repo-server -n argocd
