variable "location" {
  type    = string
  default = "centralindia"
}
variable "resource_group_name" {
  type    = string
  default = "rg-sms-dev"
}
variable "aks_name" {
  type    = string
  default = "aks-sms-dev"
}
variable "node_count" {
  type    = number
  default = 1
}
variable "node_vm_size" {
  type        = string
  default     = "Standard_B2s"
  description = "Agar quota/availability error aaye to Standard_D2s_v3 ya Standard_B2ms try karo"
}
