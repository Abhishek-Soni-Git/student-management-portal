variable "location" {
  type    = string
  default = "centralindia"
}

variable "resource_group_name" {
  type        = string
  default     = "rg-sms-dev"
  description = "Created by scripts/bootstrap.sh, not by Terraform (so the infra identity needs no subscription-level rights)."
}

variable "aks_name" {
  type    = string
  default = "aks-sms-dev"
}

variable "kubernetes_namespace" {
  type    = string
  default = "sms"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "node_vm_size" {
  type        = string
  default     = "Standard_B2s_v2"
  description = "If you hit a quota/availability error try Standard_D2s_v3 or Standard_B2ms."
}

variable "deploy_principal_object_id" {
  type        = string
  description = "Object ID of the deploy identity (GitHub variable DEPLOY_SP_OBJECT_ID)."
}

variable "tags" {
  type = map(string)
  default = {
    app        = "student-management-portal"
    managed_by = "terraform"
  }
}
