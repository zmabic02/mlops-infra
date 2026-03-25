# =============================================================================
# Makefile for infra repo
# =============================================================================

.PHONY: help bootstrap validate apply-all apply-root status sync port-forward dashboard logs clean restart-argocd

GREEN  := \033[0;32m
YELLOW := \033[0;33m
RESET  := \033[0m

help: ## Show available commands
	@echo "========================================"
	@echo "  Available commands:"
	@echo "========================================"
	@awk 'BEGIN {FS = ":.*##"; printf "\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  ${GREEN}%-25s${RESET} %s\n", $$1, $$2 }' $(MAKEFILE_LIST)


bootstrap: ## Initial installation (k3s + ArgoCD)
	@echo "${YELLOW}→ Starting bootstrap...${RESET}"
	./bootstrap/k3s-install.sh
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd \
		--server-side \
		--force-conflicts \
		-f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	@echo "${GREEN}ArgoCD installed"


validate: ## Validate all manifests (kustomize + kubeconform)
	@echo "${YELLOW}Validating manifests...${RESET}"
	kustomize build argocd/applications/ | kubeconform --summary -strict
	@echo "${GREEN}Validation successful${RESET}"


apply-root: ## Apply only root App-of-Apps
	@echo "${YELLOW}Applying root App-of-Apps...${RESET}"
	kustomize build argocd/applications/ | kubectl apply -f -
	@echo "${GREEN}Done${RESET}"

apply-all: validate apply-root ## Validate + apply all


status: ## Show application status
	@echo "${YELLOW}ArgoCD Application status:${RESET}"
	kubectl get applications -n argocd -o wide

sync: ## Manually synchronize all applications
	@echo "${YELLOW}Manually synchronizing applicactions...${RESET}"
	argocd app sync --all --prune

port-forward: ## Port-forward for ArgoCD UI[](http://localhost:8080)
	kubectl port-forward -n argocd svc/argocd-server 8080:80

dashboard: ## Open ArgoCD UI in browser
	@echo "Opening ArgoCD UI in http://localhost:8080"
	xdg-open http://localhost:8080 2>/dev/null || open http://localhost:8080 2>/dev/null || echo "Open manually: http://localhost:8080"


logs: ## Show Application Controller logs
	kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100

restart-argocd: ## Restart ArgoCD controller
	kubectl rollout restart deployment argocd-application-controller -n argocd
	kubectl rollout restart deployment argocd-repo-server -n argocd

clean: ## Delete all ArgoCD applications
	@echo "${YELLOW}Deleting ArgoCD applications...${RESET}"
	kubectl delete -n argocd -f argocd/applications/root-app.yaml --ignore-not-found
	@echo "${GREEN}Applications deleted${RESET}"