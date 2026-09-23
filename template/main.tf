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

# Not exposed as a coder_parameter on purpose — placement is an admin decision
variable "vm_pool" {
  type        = string
  default     = ""
  description = "Proxmox resource pool to place workspace VMs in (leave empty for no pool)"
}

# Not exposed as a coder_parameter on purpose — backup policy is an admin decision
variable "backup_vm_disk" {
  type        = bool
  default     = false
  description = "Whether the workspace VM disk is included in Proxmox backups"
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

variable "default_cpu_cores" {
  type        = number
  default     = 2
  description = "Default and minimum CPU cores for new workspaces"
}

variable "default_memory_min" {
  type        = number
  default     = 1024
  description = "Default and minimum ballooning floor in MB"
}

variable "default_memory_max" {
  type        = number
  default     = 2048
  description = "Default and minimum maximum memory in MB"
}

variable "default_disk_size" {
  type        = number
  default     = 20
  description = "Default and minimum disk size in GB for new workspaces"
}

variable "default_full_clone" {
  type        = bool
  default     = false
  description = "Default clone type for new workspaces. Linked clones (false) are near-instant; full clones copy the whole template disk."
}

variable "default_tags" {
  type        = list(string)
  default     = ["coder"]
  description = "Tags always applied to workspace VMs. User tags are added on top, these can never be removed."
}

# -------------------------------------------------------------------
# Workspace parameters — user can override admin defaults
# Values below admin defaults are automatically raised via max()
# -------------------------------------------------------------------

data "coder_parameter" "cpu_cores" {
  name         = "cpu_cores"
  display_name = "CPU Cores"
  description  = "Number of CPU cores (minimum: ${var.default_cpu_cores})"
  type         = "number"
  default      = var.default_cpu_cores
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

data "coder_parameter" "memory_min" {
  name         = "memory_min"
  display_name = "Memory (Min)"
  description  = "Minimum guaranteed memory in MB. VM balloons down to this when idle. (minimum: ${var.default_memory_min})"
  type         = "number"
  default      = var.default_memory_min
  mutable      = true

  option {
    name  = "512 MB"
    value = "512"
  }
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
}

data "coder_parameter" "memory_max" {
  name         = "memory_max"
  display_name = "Memory (Max)"
  description  = "Maximum memory in MB. VM can grow up to this under load. (minimum: ${var.default_memory_max})"
  type         = "number"
  default      = var.default_memory_max
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
  description  = "Boot disk size in GB (minimum: ${var.default_disk_size})"
  type         = "number"
  default      = var.default_disk_size
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
  default      = var.default_full_clone
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

data "coder_parameter" "tags" {
  name         = "tags"
  display_name = "Tags"
  description  = "Additional Proxmox tags as a comma separated list (always applied: ${join(", ", var.default_tags)})"
  type         = "string"
  default      = ""
  mutable      = true
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

    # Coder mints a fresh agent token on every build and this ISO is
    # regenerated with it, so the token must be written and the agent restarted
    # on every boot. write_files/runcmd run only once per instance-id (which is
    # the workspace id below, stable across stop/start) and would leave a stale
    # token that coderd rejects with HTTP 401. bootcmd runs on every boot.
    bootcmd:
      - |
        cat > /etc/coder-agent.env <<'CODERENV'
        CODER_AGENT_TOKEN=${coder_agent.main.token}
        CODER_AGENT_URL=${data.coder_workspace.me.access_url}
        CODERENV
      # Restart the agent so it picks up the token just written above. The
      # unit gates its own start on the clock being time-synced (see its
      # ExecStartPre), so this may wait briefly on first boot; setup-git.sh
      # (below) runs independently and is not blocked by it.
      - systemctl restart coder-agent
    runcmd:
      # Git identity only — safe to run once per instance and must not run on
      # every boot (it makes a blocking curl to the Coder API).
      - su - coder -c '/home/coder/.local/bin/setup-git.sh "${var.git_author_name}" "${var.git_author_email}"'
  EOF

  # IPv4-only DHCP network-config for the NIC. Without this, cloud-init
  # generates a fallback config that also does DHCPv6 (it renders
  # `iface ens18 inet6 dhcp` into 50-cloud-init). This network has no DHCPv6
  # server, so that stanza makes `ifup` exit non-zero ("failed to bring up
  # ens18") even though the IPv4 lease succeeded — which fails
  # networking.service, stalls cloud-init in its network stage, and prevents
  # coder-agent (ordered after network-online.target) from ever starting.
  #
  # network-config **v1** is used deliberately: cloud-init's ifupdown (eni)
  # renderer turns it into a plain `iface ens18 inet dhcp` with NO inet6 line.
  # (A v2 config with a `match:` + logical name renders a bogus `iface primary`
  # for a nonexistent device, so it must not be used with the eni renderer.)
  # The NIC is a single Proxmox virtio device and enumerates as ens18.
  network_config = <<-EOF
    version: 1
    config:
      - type: physical
        name: ens18
        subnets:
          - type: dhcp4
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
# Tags — admin defaults are always applied, user tags are added on top
# Proxmox only accepts lowercase alphanumeric tags plus -_.+
# -------------------------------------------------------------------

locals {
  user_tags = [
    for tag in split(",", data.coder_parameter.tags.value) :
    lower(trimspace(tag)) if trimspace(tag) != ""
  ]

  tags = sort(distinct([
    for tag in concat(var.default_tags, local.user_tags) :
    replace(lower(trimspace(tag)), "/[^a-z0-9\\-_.+]/", "-")
  ]))
}

# -------------------------------------------------------------------
# VM — max() ensures values never go below admin defaults
# -------------------------------------------------------------------

resource "proxmox_virtual_environment_vm" "workspace" {
  node_name = var.proxmox_node
  name      = "coder-${data.coder_workspace.me.name}"
  tags      = local.tags

  # Explicitly disable the guest-agent integration. This is NOT the same as
  # simply omitting an `agent {}` block: the Packer template is built with
  # qemu_agent = true, and bpg/proxmox honors the agent flag from the VM's
  # *actual* Proxmox config, which a clone INHERITS from the template. So an
  # omitted block still leaves agent = 1 on the clone, which makes the provider
  # (a) wait up to 15m for the agent to report an IP on create, and (b) use the
  # guest agent instead of ACPI to Shutdown on `coder stop` — and if the agent
  # is not answering, that Shutdown times out and the apply hangs in
  # "Still modifying..." for minutes. Forcing enabled = false makes Proxmox use
  # ACPI for shutdown and stops the provider from waiting on the agent at all.
  # Coder never needs the VM's IP — the coder-agent dials out on its own.
  agent {
    enabled = false
  }

  # Empty string means no pool — null keeps the VM out of any pool
  pool_id = var.vm_pool != "" ? var.vm_pool : null

  stop_on_destroy = true

  # A unix-socket serial device so `qm terminal <vmid>` works on the Proxmox
  # host, giving console access when the network is down or cloud-init hangs.
  # The guest half (a getty on ttyS0 and console=ttyS0 on the kernel cmdline)
  # is baked into the Packer image.
  serial_device {}

  # Bound the shutdown/stop waits so a guest that is slow (or refuses) to power
  # down on ACPI can never wedge `terraform apply`. After timeout_shutdown_vm
  # the provider escalates to a hard stop instead of blocking indefinitely
  # (provider defaults are 1800s shutdown / 300s stop).
  timeout_shutdown_vm = 60
  timeout_stop_vm     = 60

  # Bind VM power state to the Coder workspace transition. Without this the VM
  # resource never changes on a `stop`, so `terraform apply` is a no-op and the
  # Proxmox VM keeps running — `coder stop` appears to succeed but the guest
  # stays powered on (stop_on_destroy only stops the VM on destroy/delete, not
  # on stop). start_count is 1 while the workspace is started and 0 while it is
  # stopped, so this powers the VM off on `coder stop` and back on `coder start`.
  # With agent { enabled = false } above, the power-off goes over ACPI and the
  # provider does not wait on the guest agent. on_boot is pinned to the same
  # value so a Proxmox host reboot never silently powers a stopped workspace on.
  started = data.coder_workspace.me.start_count == 1
  on_boot = data.coder_workspace.me.start_count == 1

  clone {
    vm_id = var.template_vm_id
    full  = data.coder_parameter.full_clone.value == "true"
  }

  cpu {
    cores = max(data.coder_parameter.cpu_cores.value, var.default_cpu_cores)
  }

  memory {
    dedicated = max(data.coder_parameter.memory_max.value, var.default_memory_max)
    floating  = max(data.coder_parameter.memory_min.value, var.default_memory_min)
  }

  disk {
    interface    = "scsi0"
    datastore_id = var.storage_pool
    size         = max(data.coder_parameter.disk_size.value, var.default_disk_size)
    backup       = var.backup_vm_disk
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    bridge = var.network_bridge
  }

  # The single cloud-init NoCloud seed. There is deliberately no
  # `initialization {}` block: bpg/proxmox would attach its own cloudinit drive
  # (also labelled "cidata"), giving cloud-init two seeds. cloud-init reads only
  # one (it reverse-sorts the devices), so a second seed could race and cause
  # Proxmox's network-config to be silently discarded. Attaching only this ISO
  # avoids that. What an initialization{} block would provide is covered
  # elsewhere: the `coder` user comes from the Packer preseed
  # (passwd/username=coder + NOPASSWD sudo), and DHCP comes from the
  # installer-baked /etc/network/interfaces stanza for ens18.
  cdrom {
    enabled   = true
    file_id   = proxmox_virtual_environment_file.cloud_init.id
    interface = "ide3"
  }
}
