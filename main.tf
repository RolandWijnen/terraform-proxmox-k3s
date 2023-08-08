# Generate a random cluster token for k3s
resource "random_id" "k3s_token" {
  byte_length = 35
}
resource "random_password" "db_password" {
  length  = 16
  special = false
}

locals {
  kubeconfig_path = "${path.module}/kubeconfig"
  db_user         = "k3s"
  db              = "kubernetes"
  db_port         = 3306
  db_password     = random_password.db_password.result
}

# Create the VM that will contain the database
resource "proxmox_vm_qemu" "k3s-db" {
  name        = "${var.cluster_name}-k3s-db"
  desc        = "Kubernetes MariaDB database. User: ${local.db_user} | Password: ${local.db_password} | DB: ${local.db}"
  target_node = "proxmox"

  # Hardware configuration
  agent   = 1
  clone   = var.proxmox_vm_image_name
  cores   = 1
  memory  = 1024
  balloon = 512
  sockets = 1
  cpu     = "host"
  disk {
    storage = "local"
    type    = "virtio"
    size    = var.mariadb_database_size
  }

  os_type         = "cloud-init"
  ipconfig0       = "ip=dhcp" # auto-assign a IP address for the machine
  nameserver      = "1.1.1.1"
  ciuser          = var.ciuser
  sshkeys         = var.ssh_keys
  ssh_user        = var.ciuser
  ssh_private_key = var.ssh_private_key

  # Specify connection variables for remote execution
  connection {
    type        = "ssh"
    host        = self.ssh_host # Auto-assigned ip address
    user        = self.ssh_user
    private_key = self.ssh_private_key
    port        = self.ssh_port
    timeout     = "10m"

  }

  provisioner "remote-exec" {
    # Start the database using docker
    inline = [<<EOF
      sudo docker run -d --name mariadb \
          --restart always \
          -v /opt/mysql/data:/var/lib/mysql \
          --env MYSQL_USER=${local.db_user} \
          --env MYSQL_PASSWORD=${local.db_password} \
          --env MYSQL_ROOT_PASSWORD=${local.db_password} \
          --env MYSQL_DATABASE=${local.db} \
          -p ${local.db_port}:3306 \
          mariadb:latest
    EOF
    ]
  }
  # For some reason terraform has changes on reapply
  # https://github.com/Telmate/terraform-provider-proxmox/issues/112
  lifecycle {
    ignore_changes = [
      network,
    ]
  }

}

locals {
  # Create the datastore endpoint for the cluster
  datastore_endpoint = "mysql://${local.db_user}:${random_password.db_password.result}@tcp(${proxmox_vm_qemu.k3s-db.ssh_host}:${local.db_port})/${local.db}"
  node_count         = var.server_node_count + var.agent_node_count
}


resource "proxmox_vm_qemu" "k3s-nodes" {
  depends_on  = [proxmox_vm_qemu.k3s-db]
  count       = local.node_count
  name        = "${var.cluster_name}-k3s-${count.index}"
  desc        = "Kubernetes node ${count.index}"
  target_node = "proxmox"

  # Hardware configuration
  agent   = 1
  clone   = var.proxmox_vm_image_name
  cores   = var.cores
  memory  = var.memory
  balloon = var.balloon
  sockets = 1
  cpu     = "host"
  disk {
    storage = "local"
    type    = "virtio"
    size    = var.disk_size
  }

  os_type         = "cloud-init"
  ipconfig0       = "ip=dhcp" # auto-assign a IP address for the machine
  nameserver      = "1.1.1.1"
  ciuser          = var.ciuser
  sshkeys         = var.ssh_keys
  ssh_user        = var.ciuser
  ssh_private_key = var.ssh_private_key

  # Specify connection variables for remote execution
  connection {
    type        = "ssh"
    host        = self.ssh_host # Auto-assigned ip address
    user        = self.ssh_user
    private_key = self.ssh_private_key
    port        = self.ssh_port
    timeout     = "10m"

  }


  # Provision the kubernetes cluster with k3sup
  provisioner "local-exec" {
    command = <<-EOT
      # Generate SSH private key file
      echo "${self.ssh_private_key}" > privkey
      chmod 600 privkey

      # First two nodes are server nodes for High Availability setup.
      # The next nodes are just agent nodes for deploying workloads
      if [ "${count.index}" -lt "${var.server_node_count}" ]; then
        echo "Installing server node"
        k3sup install --ip ${self.ssh_host} \
          --k3s-extra-args "--disable local-storage" \
          --user ${self.ssh_user} \
          --ssh-key privkey \
          --k3s-version ${var.k3s_version} \
          --datastore="${local.datastore_endpoint}" \
          --token=${random_id.k3s_token.b64_std} \ 
          --local-path="${local.kubeconfig_path}"
      else
        echo "Installing agent node"
        k3sup join --ip ${self.ssh_host} \
          --user ${self.ssh_user} \
          --server-user ${self.ssh_user} \
          --ssh-key privkey \
          --k3s-version ${var.k3s_version} \
          --server-ip ${proxmox_vm_qemu.k3s-nodes[0].ssh_host}
      fi

      # Cleanup private key
      rm privkey
    EOT
  }

  # For some reason terraform has changes on reapply
  # https://github.com/Telmate/terraform-provider-proxmox/issues/112
  lifecycle {
    ignore_changes = [
      network,
    ]
  }

}

