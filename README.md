# pve-guest-apt-manager

Parallel apt update/upgrade + maintenance orchestrator for Proxmox LXC containers **and Linux VMs**.

Built for real-world Proxmox environments where you want:

* One command to patch everything
* Clean logging
* Reboot detection
* Optional cleanup
* Zero babysitting

Script name used in this repo:

```
update-guests.sh
```

---

# ✨ Features

### 🚀 Parallel Guest Updates (LXC + VM)

Runs `apt update && apt upgrade` across all running guests at once.

* Supports **LXC containers + Linux VMs**
* Configurable concurrency (default: 10 at a time)
* Skips stopped guests automatically
* Live terminal dashboard with status + progress bar
* Clear success/failure reporting

VM support uses the **QEMU Guest Agent** (see requirements below).

---

### 📊 Smart Logging System

Two log levels:

**LOG_LEVEL=2 (default — recommended)**

* Clean high-level operator log
* Start/complete/fail events
* Summary + UI snapshot
* Captures full apt output *only if a guest fails*

**LOG_LEVEL=1 (debug)**

* Full apt output for all guests
* Deep troubleshooting mode

Each run creates a timestamped logfile:

```
pve-guest-apt-manager_YYYY-MM-DD_HHMMSS.log
```

Colored logs supported:

```
less -R pve-guest-apt-manager_*.log
```

---

### 🧹 Optional Cleanup Mode

After upgrades complete, prompts to run:

```
apt autoremove
apt autoclean
```

Before executing, the script shows **which guests will be affected**.

Helps keep systems lean and prevents disk bloat.

---

### 🔁 Reboot Detection

Automatically detects:

```
/var/run/reboot-required
```

Prompts to reboot only guests that actually need it and displays the affected list before confirming.

---

### 🎛 Clean Terminal UI

Live updating dashboard showing:

* Pending
* Running
* Completed
* Failed
* Skipped

Per-guest status example:

```
Grafana (CT 131)        COMPLETE
PiHole (CT 107)         RUNNING
AllStar Node (VM 100)   COMPLETE
DevTest (CT 104)        FAILED
```

---

# 📦 Installation

On your Proxmox host:

```bash
cd /root
nano update-guests.sh
```

Paste script → save.

Make executable:

```bash
chmod +x update-guests.sh
```

Optional: run from anywhere

```bash
ln -s /root/update-guests.sh /usr/local/sbin/update-guests
```

---

# ▶️ Running

Normal run:

```bash
update-guests
```

Debug mode:

```bash
LOG_LEVEL=1 update-guests
```

---

### ⏱ Note on startup

After launching, the script may take **5–15 seconds** before the terminal UI appears.

During this time it is:

* Enumerating LXCs and VMs
* Checking power state
* Checking guest agent availability
* Building execution queue
* Initializing logging/UI

It can look like it’s hanging — it isn’t.

---

# ⚙️ Configuration

Edit top of script:

```bash
MAX_JOBS=10
REFRESH_SEC=1
LOG_LEVEL=2
```

### Concurrency tuning

| Host Type       | Suggested |
| --------------- | --------- |
| Small homelab   | 4–6       |
| Modern SSD host | 8–12      |
| Big iron        | 15–25     |

---

# 🧠 Usage Examples

### Standard run

```bash
./update-guests.sh
```

### Debug mode (full apt logs)

```bash
LOG_LEVEL=1 ./update-guests.sh
```

### View logs

```bash
less -R pve-guest-apt-manager_*.log
```

---

# 🛡 Safety Behavior

* Skips stopped guests automatically
* Skips Windows VMs automatically
* Skips non-apt systems automatically
* Skips guests without working guest agent (VMs)
* Prompts before cleanup
* Prompts before reboot
* Only reboots guests that require it
* Captures apt failure output automatically
* Won’t require rerun just to see errors

---

# 🧰 Requirements

### Proxmox Host

* Proxmox VE 7/8/9
* Root shell access

### For LXC Containers

* Debian/Ubuntu based
* Uses apt

### For VMs (Linux only)

VM support requires **QEMU Guest Agent** installed and running inside the VM.

Inside each Linux VM:

```bash
apt install qemu-guest-agent -y
systemctl enable --now qemu-guest-agent
```

Also ensure in Proxmox VM settings:

```
Options → QEMU Guest Agent → Enabled
```

If guest agent is not running, the VM will be skipped or flagged.

---

# 🚫 Unsupported / Skipped Systems

The script intentionally skips:

### Windows VMs

Not supported (no apt)

### Appliance-style operating systems

Systems that are not traditional package-managed Linux installs:

* TrueNAS
* Home Assistant OS
* Router/firewall appliances
* Immutable/container-style OS builds

These are treated as **non-apt OS** and skipped automatically.

---

# ⚠️ MIT License Notice / Use At Your Own Risk

This project is licensed under the MIT License.

That means:

* You are free to use, modify, and distribute this however you want.
* There is **no warranty** or guarantee of fitness for any purpose.
* You assume all responsibility for what this script does in your environment.

This script performs package upgrades and optional reboots across multiple systems.
If you run it against production infrastructure, that decision is yours.

**Do not run this blindly in environments you do not understand.**
Test first. Know what your systems do. Be an adult.

---

# 🗺 Possible Future Improvements

* Discord/webhook summary
* Multi-node cluster support
* Dry-run mode
* Patch scheduler
* Tag/label-based guest selection
* Non-apt package manager support (dnf/yum/apk/pacman)
* Node-aware execution across cluster
* Web UI wrapper