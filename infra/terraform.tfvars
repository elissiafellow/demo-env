environment         = "demo"
aws_region          = "eu-central-1"
vpc_cidr            = "10.30.0.0/16"
eks_instance_type   = "t3.medium"
eks_min_size        = 1
eks_max_size        = 3
eks_desired_size    = 1
eks_cluster_version = "1.33" # Upgraded to support Auto Mode (simpler authentication)
