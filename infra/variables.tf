variable "environment" {
  type        = string
  description = "Environment name (e.g., 'demo')"
  default     = "demo"
}

variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for VPC"
  default     = "10.30.0.0/16"
}

variable "eks_instance_type" {
  type        = string
  description = "EC2 instance type for EKS nodes"
  default     = "t3.small"
}

variable "eks_min_size" {
  type        = number
  description = "Minimum number of EKS nodes"
  default     = 1
}

variable "eks_max_size" {
  type        = number
  description = "Maximum number of EKS nodes"
  default     = 3
}

variable "eks_desired_size" {
  type        = number
  description = "Desired number of EKS nodes"
  default     = 1
}

variable "eks_cluster_version" {
  type        = string
  description = "Kubernetes version for EKS cluster"
  default     = "1.33" # Upgraded to support Auto Mode (simpler authentication)
}












