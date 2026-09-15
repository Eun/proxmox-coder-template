terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.0, < 3.0"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.112"
    }
    cidata = {
      source  = "freefair/cidata"
      version = "~> 0.1"
    }
  }
}

# -------------------------------------------------------------------
# Template variables — set by admin in Template Settings
# -------------------------------------------------------------------

variable "proxmox_endpoint" {
  type    = string
  default = ""
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Proxmox VE API token in the format USER@REALM!TOKENID=TOKEN-SECRET (e.g. terraform@pve!provider=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)"
}

variable "proxmox_insecure" {
  type    = bool
  default = false
}

variable "proxmox_node" {
  type    = string
  default = "pve"
}

variable "template_vm_id" {
  type    = number
  default = 100
}

variable "storage_pool" {
  type    = string
  default = "local-lvm"
}

variable "iso_storage_pool" {
  type    = string
  default = "local"
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "git_author_name" {
  type        = string
  default     = ""
  description = "Default git author name for workspaces (leave empty to skip)"
}

variable "git_author_email" {
  type        = string
  default     = ""
  description = "Default git author email for workspaces (leave empty to skip)"
}

# -------------------------------------------------------------------
# Workspace parameters
# -------------------------------------------------------------------

data "coder_parameter" "cpu_cores" {
  name         = "cpu_cores"
  display_name = "CPU Cores"
  description  = "Number of CPU cores"
  type         = "number"
  default      = "2"
  mutable      = true

  option {
    name  = "1 Core"
    value = "1"
  }
  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores"
    value = "4"
  }
  option {
    name  = "8 Cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "Memory in MB"
  type         = "number"
  default      = "2048"
  mutable      = true

  option {
    name  = "1 GB"
    value = "1024"
  }
  option {
    name  = "2 GB"
    value = "2048"
  }
  option {
    name  = "4 GB"
    value = "4096"
  }
  option {
    name  = "8 GB"
    value = "8192"
  }
  option {
    name  = "16 GB"
    value = "16384"
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Disk Size"
  description  = "Boot disk size in GB (must be >= 4)"
  type         = "number"
  default      = "20"
  mutable      = false

  option {
    name  = "10 GB"
    value = "10"
  }
  option {
    name  = "20 GB"
    value = "20"
  }
  option {
    name  = "50 GB"
    value = "50"
  }
  option {
    name  = "100 GB"
    value = "100"
  }
}

data "coder_parameter" "full_clone" {
  name         = "full_clone"
  display_name = "Clone Type"
  description  = "Full clone uses more disk but is independent. Linked clone is faster but depends on the template."
  type         = "bool"
  default      = "true"
  mutable      = false

  option {
    name  = "Full Clone"
    value = "true"
  }
  option {
    name  = "Linked Clone"
    value = "false"
  }
}

# -------------------------------------------------------------------
# Provider — API only, no SSH
# -------------------------------------------------------------------

provider "proxmox" {
  endpoint  = var.proxmox_endpoint != "" ? var.proxmox_endpoint : "https://localhost:8006/"
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : "placeholder@pve!placeholder=00000000-0000-0000-0000-000000000000"
  insecure  = var.proxmox_insecure
}

# -------------------------------------------------------------------
# Coder workspace + agent
# -------------------------------------------------------------------

data "coder_workspace" "me" {}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
}

# -------------------------------------------------------------------
# Cloud-init ISO — just env file + call baked scripts
# -------------------------------------------------------------------

resource "cidata_iso" "cloud_init" {
  output_path = "${path.module}/generated/coder-${data.coder_workspace.me.id}.iso"

  user_data = <<-EOF
    #cloud-config
    write_files:
      - path: /etc/coder-agent.env
        content: |
          CODER_AGENT_TOKEN=${coder_agent.main.token}
          CODER_AGENT_URL=${data.coder_workspace.me.access_url}
    runcmd:
      - su - coder -c '/home/coder/.local/bin/setup-git.sh "${var.git_author_name}" "${var.git_author_email}"'
      - systemctl start coder-agent
  EOF

  meta_data = jsonencode({
    instance-id    = "coder-${data.coder_workspace.me.id}"
    local-hostname = "coder-${data.coder_workspace.me.name}"
  })
}

resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "iso"
  datastore_id = var.iso_storage_pool
  node_name    = var.proxmox_node

  source_file {
    path      = cidata_iso.cloud_init.output_path
    checksum  = cidata_iso.cloud_init.sha256
    file_name = "coder-${data.coder_workspace.me.id}-${substr(cidata_iso.cloud_init.sha256, 0, 8)}.iso"
  }
}

# -------------------------------------------------------------------
# VM
# -------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "workspace" {
  node_name = var.proxmox_node
  name      = "coder-${data.coder_workspace.me.name}"

  stop_on_destroy = true

  clone {
    vm_id = var.template_vm_id
    full  = data.coder_parameter.full_clone.value == "true"
  }

  cpu {
    cores = data.coder_parameter.cpu_cores.value
  }

  memory {
    dedicated = data.coder_parameter.memory.value
  }

  disk {
    interface    = "scsi0"
    datastore_id = var.storage_pool
    size         = data.coder_parameter.disk_size.value
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    bridge = var.network_bridge
  }

  cdrom {
    enabled   = true
    file_id   = proxmox_virtual_environment_file.cloud_init.id
    interface = "ide3"
  }

  initialization {
    datastore_id = var.storage_pool

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "coder"
    }
  }
}