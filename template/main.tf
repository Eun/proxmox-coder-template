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
  }
}

# -------------------------------------------------------------------
# Variables
# -------------------------------------------------------------------

variable "proxmox_endpoint" {
  type        = string
  default     = ""
  description = "Proxmox VE API endpoint (e.g. https://pve.example.com:8006/)"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Proxmox VE API token (e.g. terraform@pve!provider=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)"
}

variable "proxmox_insecure" {
  type        = bool
  default     = false
  description = "Skip TLS verification for the Proxmox API"
}

variable "proxmox_node" {
  type        = string
  default     = "pve"
  description = "Proxmox node name"
}

variable "template_vm_id" {
  type        = number
  default     = 100
  description = "VM ID of the template to clone"
}

variable "cpu_cores" {
  type        = number
  default     = 2
  description = "Number of CPU cores"
}

variable "memory" {
  type        = number
  default     = 2048
  description = "Memory in MB"
}

variable "network_bridge" {
  type        = string
  default     = "vmbr0"
  description = "Network bridge to attach the VM to"
}

variable "datastore_id" {
  type        = string
  default     = "local"
  description = "Datastore for cloud-init snippets"
}

variable "full_clone" {
  type        = bool
  default     = true
  description = "Perform a full clone (true) or linked clone (false)"
}

# -------------------------------------------------------------------
# Provider configuration
# Uses valid placeholders during push, real values from Template Settings
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
# Cloud-init snippet — uploaded via Proxmox API, no host access needed
# Delivers the agent token only; binary is pre-installed in template
# -------------------------------------------------------------------

resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = var.datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data = <<-EOF
    #cloud-config
    write_files:
      - path: /etc/coder-agent.env
        content: |
          CODER_AGENT_TOKEN=${coder_agent.main.token}
          CODER_AGENT_URL=${data.coder_workspace.me.access_url}
    runcmd:
      - systemctl enable coder-agent
      - systemctl start coder-agent
    EOF

    file_name = "coder-${data.coder_workspace.me.id}.yaml"
  }
}

# -------------------------------------------------------------------
# VM — cloned from template with coder agent pre-installed
# -------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "workspace" {
  node_name = var.proxmox_node
  name      = "coder-${data.coder_workspace.me.name}"

  stop_on_destroy = true

  clone {
    vm_id = var.template_vm_id
    full  = var.full_clone
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init.id
  }
}