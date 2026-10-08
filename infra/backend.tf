terraform {
  backend "azurerm" {
    # resource_group_name, storage_account_name, container_name workflow me -backend-config se aate hain
    key              = "sms.tfstate"
    use_oidc         = true
    use_azuread_auth = true
  }
}
