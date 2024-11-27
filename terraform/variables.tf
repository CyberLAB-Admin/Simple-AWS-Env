variable "project_prefix" {
  description = "Prefix for all resources"
  type        = string
}

variable "mongodb_password" {
  description = "MongoDB admin password"
  type        = string
  sensitive   = true
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
}