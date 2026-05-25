# =============================================================================
# Makefile for infra repo
# =============================================================================

.PHONY: help install-argocd-cli install-ksops install-kubeflow-kustomize argocd-login add-argocd-repo bootstrap install-gpu-plugin validate-gpu create-sops-age-secret configure-argocd-sops install-kubeflow uninstall-kubeflow validate validate-kubeflow validate-mlflow apply-mlflow-app port-forward clean restart-argocd kubeflow-dash

ARGOCD_NAMESPACE ?= argocd
ARGOCD_SERVER ?= localhost:8080
ARGOCD_OPTS ?= --grpc-web --insecure
ARGOCD_REPO_URL ?= https://github.com/zmabic02/mlops-infra.git
ARGOCD_REPO_SECRET_NAME ?= repo-mlops-infra
KSOPS_INSTALL_DIR ?= $(HOME)/.local/bin
SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt
KUBEFLOW_KUSTOMIZE_BIN ?= $(HOME)/.local/bin/kustomize_5_2_1
ENABLE_GPU ?= false
NVIDIA_DEVICE_PLUGIN_VERSION ?= v0.17.1

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*##"; printf "\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  %-25s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

install-argocd-cli:	## automatic ArgoCD CLI install
	@command -v argocd >/dev/null 2>&1 || { \
		tmp_file=$$(mktemp); \
		latest=$$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep '"tag_name"' | cut -d '"' -f 4); \
		curl -fsSL -o $$tmp_file "https://github.com/argoproj/argo-cd/releases/download/$${latest}/argocd-linux-amd64"; \
		sudo install -m 0755 $$tmp_file /usr/local/bin/argocd; \
		rm -f $$tmp_file; \
	}

install-ksops: ## Install KSOPS locally for Kustomize/SOPS validation
	@mkdir -p $(KSOPS_INSTALL_DIR)
	@tmp_dir=$$(mktemp -d); \
		cd $$tmp_dir && \
		curl -fsSLO https://github.com/viaduct-ai/kustomize-sops/releases/latest/download/ksops_latest_Linux_x86_64.tar.gz && \
		tar -xzf ksops_latest_Linux_x86_64.tar.gz && \
		install -m 0755 ksops $(KSOPS_INSTALL_DIR)/ksops

install-kubeflow-kustomize: ## Install the pinned Kustomize version used for Kubeflow rendering
	@mkdir -p $(dir $(KUBEFLOW_KUSTOMIZE_BIN))
	@tmp_dir=$$(mktemp -d); \
		cd $$tmp_dir && \
		curl -fsSLO https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.2.1/kustomize_v5.2.1_linux_amd64.tar.gz && \
		tar -xzf kustomize_v5.2.1_linux_amd64.tar.gz && \
		install -m 0755 kustomize $(KUBEFLOW_KUSTOMIZE_BIN)


argocd-login: install-argocd-cli ## Login to ArgoCD CLI (needs make argocd-dash)
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
	  "  password: $$GITHUB_TOKEN" | kubectl apply -f -
	

bootstrap: install-argocd-cli ## Initial installation (k3s + ArgoCD)
	ENABLE_GPU=$(ENABLE_GPU) ./bootstrap/k3s-install.sh
	@if [ "$(ENABLE_GPU)" = "true" ]; then $(MAKE) install-gpu-plugin; fi
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd \
		--server-side \
		--force-conflicts \
		-f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

install-gpu-plugin: ## Install the NVIDIA device plugin on the current cluster
	kubectl get runtimeclass nvidia >/dev/null
	kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/$(NVIDIA_DEVICE_PLUGIN_VERSION)/deployments/static/nvidia-device-plugin.yml
	kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system --type='merge' -p '{"spec":{"template":{"spec":{"runtimeClassName":"nvidia"}}}}'
	kubectl rollout status daemonset/nvidia-device-plugin-daemonset -n kube-system --timeout=180s

validate-gpu: ## Check whether the cluster advertises NVIDIA GPU resources
	kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset
	kest_ready=$$(kubectl get daemonset -n kube-system nvidia-device-plugin-daemonset -o jsonpath='{.status.numberReady} {.status.desiredNumberScheduled}'); \
	if [ "$$kest_ready" = "0 0" ]; then \
		echo "NVIDIA device plugin daemonset is not scheduled on any node"; \
		exit 1; \
	fi; \
	if [ "$${kest_ready%% *}" != "$${kest_ready##* }" ]; then \
		echo "NVIDIA device plugin daemonset is not fully ready: $$kest_ready"; \
		exit 1; \
	fi
	kubectl describe node $$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') | grep 'nvidia.com/gpu'

create-sops-age-secret: ## Create or update the ArgoCD secret that mounts the local SOPS age key
	@if [ ! -f $(SOPS_AGE_KEY_FILE) ]; then echo "SOPS age key file not found at $(SOPS_AGE_KEY_FILE)" && exit 1; fi
	@kubectl -n $(ARGOCD_NAMESPACE) create secret generic sops-age \
		--from-file=keys.txt=$(SOPS_AGE_KEY_FILE) \
		--dry-run=client -o yaml | kubectl apply -f -

configure-argocd-sops: ## Patch ArgoCD repo-server and argocd-cm for KSOPS/SOPS support
	@kubectl patch configmap argocd-cm -n $(ARGOCD_NAMESPACE) --type merge --patch-file argocd/sops/argocd-cm-patch.yaml
	@kubectl patch deployment argocd-repo-server -n $(ARGOCD_NAMESPACE) --type strategic --patch-file argocd/sops/argocd-repo-server-patch.yaml
	@kubectl rollout restart deployment argocd-repo-server -n $(ARGOCD_NAMESPACE)

install-kubeflow: install-kubeflow-kustomize ## Install the selected Kubeflow components for local k3s/WSL
	KUSTOMIZE_BIN="$(KUBEFLOW_KUSTOMIZE_BIN)" ./kubeflow/install.sh

uninstall-kubeflow: install-kubeflow-kustomize ## Uninstall the scripted Kubeflow installation from the cluster
	KUSTOMIZE_BIN="$(KUBEFLOW_KUSTOMIZE_BIN)" ./kubeflow/uninstall.sh

clean: ## Delete entire k3s cluster and kubeconfig
	./bootstrap/k3s-uninstall.sh


validate: ## Validate all manifests (kustomize + kubeconform)
	$(KUBEFLOW_KUSTOMIZE_BIN) build kubeflow/overlays/k3s >/dev/null
	PATH="$(KSOPS_INSTALL_DIR):$$PATH" kustomize build --enable-alpha-plugins --enable-exec mlflow >/dev/null
	@if command -v kubeconform >/dev/null 2>&1; then \
		kustomize build argocd/applications/ | kubeconform --summary -strict; \
	else \
		echo "kubeconform not found, skipping schema validation for Argo CD manifests"; \
		kustomize build argocd/applications/ >/dev/null; \
	fi


validate-kubeflow: install-kubeflow-kustomize ## Validate Kubeflow kustomization render
	$(KUBEFLOW_KUSTOMIZE_BIN) build kubeflow/overlays/k3s >/dev/null


validate-mlflow: ## Validate MLflow kustomization render including KSOPS-generated secrets
	PATH="$(KSOPS_INSTALL_DIR):$$PATH" kustomize build --enable-alpha-plugins --enable-exec mlflow >/dev/null


apply-mlflow-app: ## Apply the MLflow Argo CD Application
	kustomize build argocd/applications/ | kubectl apply -f -

argocd-dash: ## Port-forward for ArgoCD UI to http://localhost:8080
	kubectl port-forward -n argocd svc/argocd-server 8080:80

kubeflow-dash: ## Port-forward Kubeflow dashboard to http://localhost:8081
	kubectl port-forward -n istio-system svc/istio-ingressgateway 8081:80

restart-argocd: ## Restart ArgoCD controller
	kubectl rollout restart deployment argocd-application-controller -n argocd
	kubectl rollout restart deployment argocd-repo-server -n argocd
