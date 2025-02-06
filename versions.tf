terraform {
  required_providers {
    # https://github.com/Telmate/terraform-provider-proxmox
    proxmox = {
      source  = "telmate/proxmox"
      version = ">=3.0.1-rc6"
    }
    aws = {
      source = "hashicorp/aws"
    }
  }
}

