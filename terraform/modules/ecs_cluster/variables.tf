variable "name_prefix" {
  description = "Prefix for resource names (e.g. \"acc\")."
  type        = string
}

variable "tags" {
  description = "Tags applied to resources."
  type        = map(string)
  default     = {}
}
