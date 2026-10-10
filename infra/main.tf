terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8"
    }
  }
}

# subscription / tenant / client come from ARM_* env vars (OIDC) set by the workflow.
provider "azurerm" {
  features {}
  # The infra identity has no subscription-level rights, so it must not try to register providers.
  # (Microsoft.ContainerService, ContainerRegistry, Compute, Storage, Network are already Registered.)
  resource_provider_registrations = "none"
}

data "azurerm_client_config" "current" {}

# Created by bootstrap.sh
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

locals {
  # Must match scripts/bootstrap.sh: sha1(subscription_id)[0:8]
  acr_name = "acrsms${substr(sha1(data.azurerm_client_config.current.subscription_id), 0, 8)}"

  # Built-in role definition IDs (these are the only roles the infra identity may assign - see bootstrap.sh)
  role_acr_pull          = "7f951dda-4ed3-4680-a7ca-43fe172d538d"
  role_acr_push          = "8311e382-0749-4cb8-b61a-304f252e45ec"
  role_aks_cluster_user  = "4abbcc35-e782-43d8-92c5-2d3f1bd2253f"
  role_aks_rbac_writer   = "a7ffa36f-339b-4b5c-8bdf-e2c188b2c0eb"
  role_aks_rbac_cl_admin = "b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b"
}

# ---------------------------------------------------------------- ACR
resource "azurerm_container_registry" "acr" {
  name                = local.acr_name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false # no shared admin username/password, Entra ID only
  tags                = var.tags
}

# ---------------------------------------------------------------- AKS
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.aks_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  dns_prefix          = var.aks_name
  sku_tier            = "Free"
  tags                = var.tags

  # --- identity & access
  local_account_disabled            = true # no static cluster-admin kubeconfig
  role_based_access_control_enabled = true
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true # Kubernetes authz via Azure role assignments
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }
  oidc_issuer_enabled       = true
  workload_identity_enabled = true # pods can get Entra tokens without secrets (future use)

  identity {
    type = "SystemAssigned"
  }

  # --- patching
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"
  image_cleaner_enabled     = true

  default_node_pool {
    name                        = "system"
    node_count                  = var.node_count
    vm_size                     = var.node_vm_size
    temporary_name_for_rotation = "systmp"
    upgrade_settings {
      max_surge = "10%"
    }
  }

  # --- network: Azure CNI overlay + Cilium so NetworkPolicy is actually enforced
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
  }

  # Managed NGINX ingress (ingressClassName: webapprouting.kubernetes.azure.com)
  web_app_routing {
    dns_zone_ids = []
  }
}

# ---------------------------------------------------------------- role assignments
# Nodes pull images from ACR with the kubelet identity - no image pull secrets.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_id               = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_acr_pull}"
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Deploy identity: push images ...
resource "azurerm_role_assignment" "deploy_acr_push" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_id               = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_acr_push}"
  principal_id                     = var.deploy_principal_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# ... fetch a kubeconfig ...
resource "azurerm_role_assignment" "deploy_aks_cluster_user" {
  scope                            = azurerm_kubernetes_cluster.aks.id
  role_definition_id               = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_aks_cluster_user}"
  principal_id                     = var.deploy_principal_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# ... and write objects ONLY inside the app namespace (not cluster-wide).
resource "azurerm_role_assignment" "deploy_namespace_writer" {
  scope                            = "${azurerm_kubernetes_cluster.aks.id}/namespaces/${var.kubernetes_namespace}"
  role_definition_id               = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_aks_rbac_writer}"
  principal_id                     = var.deploy_principal_object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

# Infra identity applies k8s/base (namespace, pod-security labels, network policies).
resource "azurerm_role_assignment" "infra_aks_cluster_user" {
  scope                            = azurerm_kubernetes_cluster.aks.id
  role_definition_id               = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_aks_cluster_user}"
  principal_id                     = data.azurerm_client_config.current.object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "infra_aks_cluster_admin" {
  scope                            = azurerm_kubernetes_cluster.aks.id
  role_definition_id               = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.role_aks_rbac_cl_admin}"
  principal_id                     = data.azurerm_client_config.current.object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
