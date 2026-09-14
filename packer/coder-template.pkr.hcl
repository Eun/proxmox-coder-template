packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.4"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# -------------------------------------------------------------------
# Variables
# -------------------------------------------------------------------

variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL (e.g. https://pve.example.com:8006/api2/json)"
}

variable "proxmox_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token"
}

variable "proxmox_node" {
  type    = string
  default = "pve"
}

variable "vm_id" {
  type    = number
  default = 100
}

variable "disk_storage_pool" {
  type    = string
  default = "local-lvm"
}

variable "iso_storage_pool" {
  type    = string
  default = "local"
}

variable "cloud_init_storage_pool" {
  type    = string
  default = "local-lvm"
}

variable "iso_file" {
  type    = string
  default = ""
}

variable "iso_url" {
  type    = string
  default = "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso"
}

variable "iso_checksum" {
  type    = string
  default = "sha256:65273beed27b2df543b68b65630ba525cfbad8df2b12035732b2dff87d6664e7"
}

variable "preseed_loader_url" {
  type        = string
  default     = "https://raw.githubusercontent.com/Eun/proxmox-coder-template/refs/heads/main/packer/preseed-loader.cfg"
  description = "URL to the preseed loader file that mounts the CD and chainloads the full preseed"
}

# -------------------------------------------------------------------
# Full preseed content
# -------------------------------------------------------------------

locals {
  preseed = <<-EOF
  #_preseed_V1
  d-i debian-installer/language string en
  d-i debian-installer/country string US
  d-i debian-installer/locale string en_US.UTF-8
  d-i keyboard-configuration/xkb-keymap select us

  d-i netcfg/choose_interface select auto
  d-i netcfg/link_wait_timeout string 5
  d-i netcfg/dhcp_timeout string 60
  d-i netcfg/get_hostname string coder-template
  d-i netcfg/get_domain string local

  d-i mirror/country string manual
  d-i mirror/http/hostname string deb.debian.org
  d-i mirror/http/directory string /debian
  d-i mirror/http/proxy string

  d-i passwd/root-login boolean true
  d-i passwd/root-password password root
  d-i passwd/root-password-again password root
  d-i passwd/make-user boolean true
  d-i passwd/user-fullname string coder
  d-i passwd/username string coder
  d-i passwd/user-password password packer
  d-i passwd/user-password-again password packer

  d-i clock-setup/utc boolean true
  d-i time/zone string UTC
  d-i clock-setup/ntp boolean true

  d-i partman-auto/disk string /dev/sda
  d-i partman-auto/method string regular
  d-i partman-auto/choose_recipe select atomic
  d-i partman-partitioning/confirm_write_new_label boolean true
  d-i partman/choose_partition select finish
  d-i partman/confirm boolean true
  d-i partman/confirm_nooverwrite boolean true

  d-i base-installer/install-recommends boolean false
  d-i apt-setup/cdrom/set-first boolean false
  d-i apt-setup/use_mirror boolean true
  tasksel tasksel/first multiselect ssh-server
  d-i pkgsel/include string qemu-guest-agent sudo cloud-init curl ca-certificates
  d-i pkgsel/upgrade select safe-upgrade
  popularity-contest popularity-contest/participate boolean false

  d-i preseed/late_command string \
      in-target sh -c 'echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder'; \
      in-target chmod 440 /etc/sudoers.d/coder

  d-i grub-installer/only_debian boolean true
  d-i grub-installer/bootdev string default

  d-i finish-install/reboot_in_progress note
  d-i cdrom-detect/eject boolean true
  EOF
}

# -------------------------------------------------------------------
# Source
# -------------------------------------------------------------------

source "proxmox-iso" "debian-coder" {
  proxmox_url              = var.proxmox_url
  username                 = split("=", var.proxmox_token)[0]
  token                    = split("=", var.proxmox_token)[1]
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  vm_id                = var.vm_id
  vm_name              = "coder-debian-template"
  template_name        = "coder-debian-template"
  template_description = "Debian 13 minimal with Coder agent — built ${timestamp()}"
  tags                 = "coder;debian;template"

  os       = "l26"
  cpu_type = "host"
  cores    = 2
  memory   = 2048
  machine  = "q35"
  bios     = "seabios"

  scsi_controller = "virtio-scsi-single"

  disks {
    type         = "scsi"
    disk_size    = "4G"
    storage_pool = var.disk_storage_pool
    io_thread    = true
    discard      = true
  }

  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  dynamic "boot_iso" {
    for_each = var.iso_file != "" ? [] : [1]
    content {
      type             = "ide"
      index            = "0"
      iso_url          = var.iso_url
      iso_checksum     = var.iso_checksum
      iso_storage_pool = var.iso_storage_pool
      unmount          = true
    }
  }

  dynamic "boot_iso" {
    for_each = var.iso_file != "" ? [1] : []
    content {
      type     = "ide"
      index    = "0"
      iso_file = var.iso_file
      unmount  = true
    }
  }

  additional_iso_files {
    type             = "ide"
    index            = "2"
    iso_storage_pool = var.iso_storage_pool
    unmount          = true
    cd_label         = "preseed"
    cd_content = {
      "/preseed.cfg" = local.preseed
    }
  }

  boot_command = [
    "<wait5>",
    "<down><wait>",
    "<tab>",
    " auto=true url=${var.preseed_loader_url}",
    " hostname=coder-template domain=local",
    " interface=auto noprompt quiet --",
    "<enter>"
  ]
  boot_wait = "5s"

  ssh_username = "coder"
  ssh_password = "packer"
  ssh_timeout  = "30m"

  cloud_init              = true
  cloud_init_storage_pool = var.cloud_init_storage_pool

  qemu_agent = true
}

# -------------------------------------------------------------------
# Build
# -------------------------------------------------------------------

build {
  sources = ["source.proxmox-iso.debian-coder"]

  # Install coder binary
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y curl",
      "curl -fsSL https://coder.com/install.sh | sh -s -- --method standalone",
      "sudo mv ~/.local/bin/coder /usr/local/bin/coder || true",
      "sudo chmod +x /usr/local/bin/coder",
    ]
  }

  # Create systemd service — cloud-init writes env file and starts it via runcmd
  provisioner "shell" {
    inline = [
      "sudo tee /etc/systemd/system/coder-agent.service > /dev/null <<'EOF'",
      "[Unit]",
      "Description=Coder Agent",
      "After=network-online.target",
      "Wants=network-online.target",
      "",
      "[Service]",
      "Type=simple",
      "EnvironmentFile=/etc/coder-agent.env",
      "ExecStart=/usr/local/bin/coder agent",
      "Restart=always",
      "RestartSec=5",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "EOF",

      "sudo systemctl daemon-reload",
    ]
  }

  # Clean up for template
  provisioner "shell" {
    inline = [
      "sudo cloud-init clean --logs",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo sync",
    ]
  }
}