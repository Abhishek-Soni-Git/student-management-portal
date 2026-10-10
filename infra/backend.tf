terraform {
  backend "azurerm" {
    # resource_group_name / storage_account_name / container_name come from -backend-config in the workflow.
    key              = "sms.tfstate"
    use_oidc         = true
    use_azuread_auth = true # Entra ID only; the storage account has shared keys disabled
  }
}
