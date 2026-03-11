# ============================================================================
# IMPORTANT NOTE: EKS Addons Installation
# ============================================================================
# 
# EKS Addons (VPC CNI, kube-proxy, CoreDNS, EBS CSI Driver) should be installed
# MANUALLY via AWS Console AFTER the cluster and node group are created.
#
# Installation order:
# 1. Create cluster (terraform apply)
# 2. Create node group (terraform apply)
# 3. Install addons manually: EKS Console → Clusters → demo-eks → Add-ons
#    - Install: vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver
# 4. Wait for addons to install (2-3 minutes)
# 5. Nodes will become fully ready once VPC CNI is installed
#
# Why manual installation?
# - Avoids circular dependency issues (addons need nodes, nodes need addons)
# - Faster troubleshooting and recovery
# - More control over addon versions
#
# ============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Use local backend for demos (change to S3 if needed)
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region
}

# Reference: devops-iaac-terraform-modules/environment_network
# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.environment}-vpc"
    Environment = var.environment
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name        = "${var.environment}-igw"
    Environment = var.environment
  }
}

# Get availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Public Subnets
# Why 2 subnets? For high availability across availability zones (AZs)
# If one AZ fails, resources in the other AZ continue working
# Minimum 2 AZs recommended for production, but for demos 1 is fine
resource "aws_subnet" "public" {
  count  = 2
  vpc_id = aws_vpc.main.id
  # cidrsubnet(base_cidr, newbits, netnum)
  # base_cidr: 10.30.0.0/16 (16 bits for network)
  # newbits: 8 (add 8 more bits for subnetting = /24 subnets)
  # netnum: count.index (0, 1, 2...) - which subnet number
  # Result: 10.30.0.0/24, 10.30.1.0/24, etc.
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = {
    Name        = "${var.environment}-public-${count.index + 1}"
    Environment = var.environment
    Type        = "public"
  }
}

# Private Subnets
# Why 2 subnets? Same reason - high availability across AZs
# EKS requires subnets in at least 2 AZs for proper node distribution
# count.index + 2 ensures no overlap with public subnets (0,1)
resource "aws_subnet" "private" {
  count  = 2
  vpc_id = aws_vpc.main.id
  # count.index + 2 means: 10.30.2.0/24, 10.30.3.0/24 (after public: 0,1)
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 2)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name        = "${var.environment}-private-${count.index + 1}"
    Environment = var.environment
    Type        = "private"
  }
}

# NAT Gateway (single for cost optimization)
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "${var.environment}-nat-eip"
    Environment = var.environment
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "${var.environment}-nat"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.main]
}

# Route Table - Public
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-public-rt"
    Environment = var.environment
  }
}

# Route Table - Private
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name        = "${var.environment}-private-rt"
    Environment = var.environment
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Reference: devops-iaac-terraform-modules/S3
# S3 Bucket for ALB logs
# Note: ALB logs can go to S3 OR CloudWatch Logs
# S3: Better for long-term storage, cheaper for large volumes, easier to analyze
# CloudWatch: Better for real-time monitoring, integrated with AWS services
# For demos, you can skip this and use CloudWatch Logs instead if preferred
# resource "aws_s3_bucket" "alb_logs" {
#   bucket = "${var.environment}-alb-logs-${data.aws_caller_identity.current.account_id}"

#   tags = {
#     Name        = "${var.environment}-alb-logs"
#     Environment = var.environment
#   }
# }

# resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
#   bucket = aws_s3_bucket.alb_logs.id

#   rule {
#     apply_server_side_encryption_by_default {
#       sse_algorithm = "AES256"
#     }
#   }
# }

# resource "aws_s3_bucket_public_access_block" "alb_logs" {
#   bucket = aws_s3_bucket.alb_logs.id

#   block_public_acls       = true
#   block_public_policy     = true
#   ignore_public_acls      = true
#   restrict_public_buckets = true
# }

data "aws_caller_identity" "current" {}

# Reference: devops-iaac-terraform-modules/cloud_eks_cluster
# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = "${var.environment}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_cluster_version

  # Match existing cluster configuration to prevent replacement
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
  ]

  tags = {
    Name        = "${var.environment}-eks"
    Environment = var.environment
  }
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "${var.environment}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.environment}-eks-cluster-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# EKS Node Group IAM Role
resource "aws_iam_role" "eks_node_group" {
  name = "${var.environment}-eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.environment}-eks-node-group-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group.name
}

# EKS Node Group
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.environment}-node-group"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = var.eks_desired_size
    max_size     = var.eks_max_size
    min_size     = var.eks_min_size
  }

  instance_types = [var.eks_instance_type]

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]

  tags = {
    Name        = "${var.environment}-node-group"
    Environment = var.environment
    # Autoscaling tags for cluster autoscaler (deployed via ArgoCD)
    "k8s.io/cluster-autoscaler/enabled"                      = "true"
    "k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}" = "owned"
  }
}

# ============================================================================
# EKS Addons (Required for cluster functionality)
# ============================================================================

# VPC CNI - Required for pod networking (assigns VPC IPs to pods)
# NOTE: Install manually via AWS Console after node group is created
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main
  ]

  tags = {
    Name        = "${var.environment}-vpc-cni"
    Environment = var.environment
  }
}

# kube-proxy - Required for service networking (enables Kubernetes services)
# NOTE: Install manually via AWS Console after node group is created
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main
  ]

  tags = {
    Name        = "${var.environment}-kube-proxy"
    Environment = var.environment
  }
}

# CoreDNS - Required for DNS resolution within the cluster
# NOTE: Install manually via AWS Console after node group is created
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main
  ]

  tags = {
    Name        = "${var.environment}-coredns"
    Environment = var.environment
  }
}

# EBS CSI Driver - Required for persistent volumes (already have IAM role configured)
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi_driver.arn
  resolve_conflicts_on_update = "OVERWRITE"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role.ebs_csi_driver
  ]

  tags = {
    Name        = "${var.environment}-ebs-csi-driver"
    Environment = var.environment
  }
}

# we must understand this
# OIDC Provider for IRSA (IAM Roles for Service Accounts)
# Required for cluster autoscaler and other services to authenticate to AWS
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = {
    Name        = "${var.environment}-eks-irsa"
    Environment = var.environment
  }

  lifecycle {
    # If state has reference to OIDC provider in different account, remove from state first:
    # terraform state rm aws_iam_openid_connect_provider.eks
    create_before_destroy = true
  }
}


# ============================================================================
# EBS CSI Driver IAM Role (IRSA)
# ============================================================================

# Trust Policy for EBS CSI Driver Role
data "aws_iam_policy_document" "ebs_csi_driver_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
  }
}

# IAM Role for EBS CSI Driver
resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${var.environment}-ebs-csi-driver-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume_role.json

  tags = {
    Name        = "${var.environment}-ebs-csi-driver-role"
    Environment = var.environment
  }

  depends_on = [aws_iam_openid_connect_provider.eks]
}

# Attach AWS Managed Policy for EBS CSI Driver
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ============================================================================
# Cluster Autoscaler IAM Role (IRSA)
# ============================================================================

# Trust Policy for Cluster Autoscaler Role
data "aws_iam_policy_document" "cluster_autoscaler_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
  }
}

# IAM Policy for Cluster Autoscaler
resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "${var.environment}-cluster-autoscaler-policy"
  description = "Policy for Cluster Autoscaler to manage Auto Scaling Groups"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name        = "${var.environment}-cluster-autoscaler-policy"
    Environment = var.environment
  }
}

# IAM Role for Cluster Autoscaler
# Note: Using fixed name "eks-cluster-autoscaler" to match Helm chart configuration
resource "aws_iam_role" "cluster_autoscaler" {
  name               = "eks-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role.json

  tags = {
    Name        = "eks-cluster-autoscaler"
    Environment = var.environment
  }

  depends_on = [aws_iam_openid_connect_provider.eks]
}

# Attach Policy to Role
resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}
