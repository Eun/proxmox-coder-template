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
  d-i partman-auto/expert_recipe string \
      single-root :: \
          1 1 -1 ext4 \
              $primary{ } $bootable{ } \
              method{ format } format{ } \
              use_filesystem{ } filesystem{ ext4 } \
              mountpoint{ / } \
          .
  d-i partman-partitioning/confirm_write_new_label boolean true
  d-i partman/choose_partition select finish
  d-i partman/confirm boolean true
  d-i partman/confirm_nooverwrite boolean true
  d-i partman-basicfilesystems/no_swap boolean false

  d-i base-installer/install-recommends boolean false
  d-i apt-setup/cdrom/set-first boolean false
  d-i apt-setup/use_mirror boolean true
  tasksel tasksel/first multiselect ssh-server
  d-i pkgsel/include string qemu-guest-agent sudo cloud-init curl ca-certificates cloud-guest-utils openssh-client git jq make gnupg
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

  # Do NOT add a cloud-init drive to the template. `cloud_init = true` attaches
  # an empty cidata Cloud-Init CDROM to the template VM, which every clone
  # inherits (as ide1: vm-<id>-cloudinit). Workspaces already ship their own
  # NoCloud seed — the token ISO on ide3 built by template/main.tf — so a
  # template-baked drive would be a SECOND cidata seed. cloud-init reads only
  # one seed (it reverse-sorts the devices), so two of them race and the wrong
  # one can win, leaving networking.service failing and the NIC without an
  # IPv4 address. Keeping this off (the plugin default) means each clone has
  # exactly one cloud-init seed.
  cloud_init = false

  qemu_agent = true
}

# -------------------------------------------------------------------
# Build
# -------------------------------------------------------------------

build {
  sources = ["source.proxmox-iso.debian-coder"]

  # Install coder, mise, uv, and graphify
  provisioner "shell" {
    inline = [
      "curl -fsSL https://coder.com/install.sh | sudo sh -s -- --method standalone",

      "curl -fsSL https://mise.run | sh",
      "sudo cp ~/.local/bin/mise /usr/local/bin/mise",
      "sudo chmod +x /usr/local/bin/mise",

      "curl -LsSf https://astral.sh/uv/install.sh | sh",
      "sudo cp ~/.local/bin/uv /usr/local/bin/uv",
      "sudo cp ~/.local/bin/uvx /usr/local/bin/uvx",
      "sudo chmod +x /usr/local/bin/uv /usr/local/bin/uvx",

      "uv tool install graphifyy",
      "sudo cp ~/.local/bin/graphify /usr/local/bin/graphify",
      "sudo chmod +x /usr/local/bin/graphify",
    ]
  }

  # Install Docker CE
  provisioner "shell" {
    inline = [
      "sudo install -m 0755 -d /etc/apt/keyrings",
      "curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg",
      "sudo chmod a+r /etc/apt/keyrings/docker.gpg",
      "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null",
      "sudo apt-get update",
      "sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin",
      "sudo usermod -aG docker coder",
      "sudo systemctl enable docker",
      "sudo systemctl enable containerd",
    ]
  }

  # Upload setup-git.sh and setup coder user environment
  provisioner "file" {
    source      = "${path.root}/scripts/setup-git.sh"
    destination = "/tmp/setup-git.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /home/coder/.local/bin",
      "sudo mv /tmp/setup-git.sh /home/coder/.local/bin/setup-git.sh",
      "sudo chmod +x /home/coder/.local/bin/setup-git.sh",
      "sudo chown -R coder:coder /home/coder/.local",
      "sudo su - coder -c 'mise trust /home/coder'",
    ]
  }

  # Verify all tools
  provisioner "shell" {
    inline = [
      "echo '=== Verifying installed tools ==='",
      "git --version",
      "jq --version",
      "make --version | head -1",
      "mise --version",
      "coder version",
      "docker --version",
      "docker compose version",
      "uv --version",
      "graphify --version",
      "test -x /home/coder/.local/bin/setup-git.sh && echo '✅ setup-git.sh'",
    ]
  }

  # Create systemd service
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
      "User=coder",
      "Environment=HOME=/home/coder",
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

  # Speed up boot — every second here is paid on every workspace start
  provisioner "shell" {
    inline = [
      # GRUB: don't sit on the menu (Debian default is 5s)
      "sudo sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub",
      "grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub && sudo sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=hidden' | sudo tee -a /etc/default/grub > /dev/null",
      "sudo update-grub",

      # cloud-init: only NoCloud is ever used (cidata ISO) — skip probing
      # EC2/Azure/etc. metadata sources that each wait on network timeouts
      "printf 'datasource_list: [ NoCloud, None ]\\n' | sudo tee /etc/cloud/cloud.cfg.d/99-datasource.cfg > /dev/null",

      # Don't let maintenance timers compete with first boot
      "sudo systemctl disable apt-daily.timer apt-daily-upgrade.timer man-db.timer 2>/dev/null || true",
    ]
  }

  # Guest half of the serial console (the VM gets its serial device from the
  # serial_device {} block in template/main.tf). Add ttyS0 as a kernel console
  # and run a login getty on it so `qm terminal <vmid>` reaches a prompt. tty0
  # is kept so the VGA/noVNC console still works; ttyS0 is listed last so
  # systemd treats it as the primary console and starts serial-getty@ttyS0,
  # which is also enabled explicitly.
  provisioner "shell" {
    inline = [
      # Append the serial consoles to GRUB_CMDLINE_LINUX. Handle both cases:
      # the line already exists (Debian ships GRUB_CMDLINE_LINUX=\"\") -> edit in
      # place; the line is somehow absent -> add it. Idempotent via the guard.
      "if ! grep -q 'console=ttyS0' /etc/default/grub; then if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then sudo sed -i 's/^GRUB_CMDLINE_LINUX=\"\\(.*\\)\"/GRUB_CMDLINE_LINUX=\"\\1 console=tty0 console=ttyS0,115200\"/' /etc/default/grub; else echo 'GRUB_CMDLINE_LINUX=\"console=tty0 console=ttyS0,115200\"' | sudo tee -a /etc/default/grub > /dev/null; fi; fi",
      "sudo update-grub",
      "sudo systemctl enable serial-getty@ttyS0.service",
    ]
  }

  # Keep IPv4 from disappearing hours after boot
  #
  # Debian 13 deprecated isc-dhcp-client. ifupdown only *Recommends*
  # "dhcpcd-base | dhcp-client", and this preseed sets install-recommends
  # false — so the only reason a DHCP client exists at all is that cloud-init
  # hard-Depends on one. That client is dhcpcd, and it behaves very
  # differently from dhclient: it stamps the address with
  # valid_lft = DHCP lease time (ipv4.c ipv4_addaddr(); IP_LIFETIME is
  # unconditional on Linux). If dhcpcd ever stops renewing, *the kernel
  # itself* deletes the address one lease-time later.
  #
  # That is exactly what happened: the installer writes "allow-hotplug ens18"
  # into /etc/network/interfaces while cloud-init's eni renderer writes
  # "auto ens18" into interfaces.d/50-cloud-init, so the NIC lands in both
  # ifupdown allow-up lists and two ifup runs race for one interface:
  #
  #   ifup[519]: dhcpcd-10.1.0 starting
  #   ifup[508]: ifup: waiting for lock on /run/network/ifstate.ens18
  #   dhcpcd[528]: ens18: leased 192.168.1.174 for 86400 seconds
  #   dhcpcd[528]: received SIGTERM, stopping          <-- 0s after the lease
  #   ifup[629]: dhcpcd already running on pid 527
  #   ifup[508]: ifup: failed to bring up ens18
  #
  # networking.service then sits in "failed" on *every* boot. Nothing looks
  # wrong because Debian's /etc/dhcpcd.conf ships "persistent", so the dead
  # client leaves a fully working routed address behind — until the lease
  # elapses and the address silently vanishes. dhcpcd-base ships no systemd
  # unit either (that's the separate "dhcpcd" package), so nothing restarts it.
  #
  # See https://github.com/canonical/cloud-init/issues/6967 for the same
  # mechanism upstream.
  provisioner "shell" {
    inline = [
      # Belt: never let the kernel expire the address. This flips dhcpcd to
      # vltime = pltime = DHCP_INFINITE_LIFETIME, so a dead client degrades
      # into a static address instead of a timed outage.
      "grep -q '^lastleaseextend' /etc/dhcpcd.conf || printf '\\n# Keep the address if dhcpcd dies; the kernel would otherwise delete it\\n# when valid_lft (= DHCP lease time) elapses.\\nlastleaseextend\\n' | sudo tee -a /etc/dhcpcd.conf > /dev/null",

      # cloud-init network rendering is intentionally left enabled: it must be
      # free to apply the DHCP network-config carried on the cidata seed (see
      # network_config in template/main.tf). In particular this build must not
      # write network:{config:disabled}; the verification step below asserts
      # that file is absent.
    ]
  }

  # Verify the networking invariants hold in the built image. Must run AFTER
  # the provisioner above. A failed networking.service still leaves a working
  # address behind (dhcpcd ships "persistent"), so without an explicit check a
  # broken image looks healthy at build time and only loses IPv4 a full lease
  # later, in production.
  provisioner "shell" {
    inline = [
      "echo '=== Verifying networking ==='",
      "grep -q '^lastleaseextend' /etc/dhcpcd.conf || { echo '❌ lastleaseextend missing from /etc/dhcpcd.conf'; exit 1; }",
      "echo '✅ lastleaseextend set'",
      "test ! -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg || { echo '❌ cloud-init network rendering is still disabled — the cidata network-config would be ignored'; exit 1; }",
      "echo '✅ cloud-init network rendering enabled'",
      "sudo systemctl is-active --quiet networking || { echo '❌ networking.service is not active'; sudo systemctl status networking --no-pager -l; exit 1; }",
      "echo '✅ networking.service active'",
      "pgrep -x dhcpcd > /dev/null || { echo '❌ no dhcpcd running — the address would have no renewer'; exit 1; }",
      "echo '✅ dhcpcd running'",
    ]
  }

  # Clean up for template
  provisioner "shell" {
    inline = [
      "sudo cloud-init clean --logs",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",

      # dhcpcd's DUID "should not be copied to other hosts" (dhcpcd.conf(5)).
      # It is generated at first run — i.e. during this build — so without
      # this every workspace cloned from the template sends an identical
      # DHCP ClientID and they all compete for the same lease.
      "sudo rm -f /var/lib/dhcpcd/duid /var/lib/dhcpcd/secret",
      "sudo rm -f /var/lib/dhcpcd/*.lease /var/lib/dhcpcd/*.lease6",

      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",

      # Return freed blocks to the storage layer so the thin-provisioned
      # template only carries allocated data — faster full clones & backups
      "sudo fstrim -av",

      "sudo sync",
    ]
  }
}