# OrbitalX

> **Hybrid Tor & Psiphon Multi-Instance Manager for Xray**

OrbitalX is a **bash‑based** tool that runs multiple Tor exit nodes and Psiphon instances on a single server, each with a **fixed port per instance**. It is designed to work alongside **Xray‑core** without touching your Xray configuration – you manually add the outbound using the port that OrbitalX provides.

---

## ✨ Key Features

- **35 predefined countries** for Tor with automatic port assignment (9080–9114)
- **28 countries supported by Psiphon** with automatic SOCKS/HTTP port assignment
- **Full country names** displayed in menus
- **Strict country enforcement** – activation fails if no exit node matches the selected country
- **Hybrid tunnel support** – create both Tor and Psiphon instances for the same country
- **Multiple instances per country** – create multiple Tor or Psiphon instances for the same country (e.g., TOR-US-1, TOR-US-2)
- **TUI (dialog) menu** for easy interactive management
- **CLI commands** for scripting and automation
- **Batch creation** – create multiple instances with one command
- **Background monitoring** with configurable interval (default 10 minutes)
- **Auto‑rotation** only when IP becomes unreachable (no unnecessary changes)
- **systemd service** integration for all instances (install / update / uninstall)
- **Per-instance logging** with live log viewing in TUI
- **No interference** with Xray – you keep full control of your config
- **Automatic Psiphon binary installation** from SpherionOS repository
- **Automatic migration** – new countries are added to the available list on update

---

## 📦 Installation

### Prerequisites
- Linux (Debian/Ubuntu recommended)
- `tor`, `curl`, `nc`, `ss`, `pgrep`, `pkill`, `dialog`, `jq`  
  (the installer will prompt you to install missing packages)

---

## 🚀 Quick Start (Run & Install from Menu)

The easiest way to try OrbitalX is to run it directly from the web:

```bash
curl -sL https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/orbitalx.sh | sudo bash
```

This will:
- Download the latest script
- Launch the **TUI menu** without installing anything yet  
- From the menu, choose `10) Administration` → `1) Install (full setup)`  
- The script will then install itself as a systemd service, create directories, and install dependencies (including Psiphon binary)

---

## ⚡ Direct Install (One‑Step)

If you prefer to install immediately without opening the menu first, run:

```bash
curl -sL https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/orbitalx.sh | sudo bash -s install
```

This will:
- Download the script
- Run the `install` command directly
- Set up everything and enable the service

---

## 📦 Full Installation (Manual)

```bash
# Clone the repository (or copy the script)
git clone https://github.com/Issei-177013/OrbitalX.git
cd OrbitalX

# Make it executable
chmod +x orbitalx.sh

# Install (systemd service + directories)
sudo ./orbitalx.sh install
```

After installation, the script is available as `/usr/local/bin/orbitalx` and the service `orbitalx.service` is enabled and started.

---

## 🖥️ Usage

### TUI Mode (Interactive)
Just run the script without any arguments:

```bash
sudo orbitalx
```

You will see a **main menu** with these options:

1. Create Instance (Tor)  
2. Create Instance (Psiphon)  
3. List/Manage Instances  
4. Show Status  
5. View Live Logs  
6. Stop/Start/Restart Instance  
7. Remove Instance  
8. Stop All Instances  
9. Set Monitor Interval  
10. Administration  
11. Exit  

Navigate with the arrow keys, press `Enter` to select, and `Tab` to switch between buttons.

---

### CLI Mode (Command‑line)

All operations are also available as commands:

```bash
sudo orbitalx <command> [arguments]
```

| Command | Description |
|---------|-------------|
| `install` | Install systemd service and directories |
| `uninstall` | Remove everything (prompts for data deletion) |
| `update` | Update to the latest version from GitHub |
| `list` | List all configured instances |
| `create <COUNTRY1> [COUNTRY2] ...` | Create BOTH Tor and Psiphon instances for countries |
| `create-tor <COUNTRY1> [COUNTRY2] ...` | Create Tor instances only |
| `create-psiphon <COUNTRY1> [COUNTRY2] ...` | Create Psiphon instances only |
| `remove <INSTANCE_ID>` | Remove an instance |
| `start <INSTANCE_ID>` | Start an instance |
| `stop <INSTANCE_ID>` | Stop an instance |
| `restart <INSTANCE_ID>` | Restart an instance |
| `status` | Show TUI status |
| `help` | Show this help |

#### Examples

```bash
# Create both Tor and Psiphon for multiple countries
sudo orbitalx create US TR GB DE

# Create Tor instances only
sudo orbitalx create-tor US TR GB

# Create Psiphon instances only
sudo orbitalx create-psiphon DE FR NL

# List all instances
orbitalx list

# Remove a specific instance
sudo orbitalx remove TOR-US-1
```

---

## 🗺️ Available Countries

### Tor (35 countries)
- Turkey, United States, France, Austria, Belgium, Romania, Canada, Singapore, Japan, Ireland, Finland, Spain, Poland, Netherlands, Italy, Switzerland, Sweden, Norway, Denmark, Iceland, Australia, India, Hong Kong, Ukraine, Czech Republic, South Korea, South Africa, Mexico, Malaysia, Azerbaijan, Cyprus, Greece, Portugal, Hungary, Luxembourg

### Psiphon (28 countries)
- Austria (AT), Belgium (BE), Bulgaria (BG), Canada (CA), Switzerland (CH), Czech Republic (CZ), Germany (DE), Denmark (DK), Estonia (EE), Spain (ES), Finland (FI), France (FR), United Kingdom (GB), Hungary (HU), Ireland (IE), India (IN), Italy (IT), Japan (JP), Latvia (LV), Netherlands (NL), Norway (NO), Poland (PL), Romania (RO), Serbia (RS), Sweden (SE), Singapore (SG), Slovakia (SK), United States (US)

---

## 🗂️ File Structure

| Path | Content |
|------|---------|
| `/etc/orbitalx/instances.conf` | All configured instances (`ID:TYPE:COUNTRY:PORT1:PORT2:STATUS`) |
| `/etc/orbitalx/port_allocator.conf` | Last allocated ports for Tor and Psiphon |
| `/etc/orbitalx/monitor_interval.conf` | Monitor interval in seconds |
| `/var/lib/orbitalx/<INSTANCE_ID>/` | Dedicated Tor data directory per instance |
| `/var/log/orbitalx/` | Log files (`manager.log`, `tor_<ID>.log`, `psiphon_<ID>.log`) |
| `/etc/psiphon/` | Psiphon binary and default config |
| `/etc/psiphon-instances/<INSTANCE_ID>/` | Psiphon instance directories |
| `/usr/local/bin/orbitalx` | Main script |
| `/usr/local/bin/VERSION` | Version file |
| `/etc/systemd/system/orbitalx-tor-<ID>.service` | Tor systemd service |
| `/etc/systemd/system/orbitalx-psiphon-<ID>.service` | Psiphon systemd service |

---

## ⚙️ Configuration

### Port Allocation

- **Tor ports**: Automatically assigned starting from **9080** (9080, 9081, 9082, ...)
- **Psiphon SOCKS ports**: Automatically assigned starting from **1080** (1080, 1081, 1082, ...)
- **Psiphon HTTP ports**: Automatically assigned starting from **8080** (8080, 8081, 8082, ...)

The exact port for each instance can be seen by running `orbitalx list`.

### Monitor Interval

Default is **600 seconds (10 minutes)**. You can change it at any time:

```bash
sudo orbitalx set-interval 300   # every 5 minutes
```

The change takes effect immediately (the systemd service is restarted).

---

## 🔄 How It Works

### Tor Activation

1. When you activate a Tor instance, OrbitalX:
   - Creates a dedicated `torrc` with `ExitNodes {country}` and `StrictNodes 1`
   - Starts a Tor daemon as a systemd service on a fixed port
   - Verifies the exit IP country against `ip-api.com`
   - If the IP does **not** match the requested country, it rotates up to 10 times
   - If no match is found, **activation fails** and the country remains available

### Psiphon Activation

1. When you activate a Psiphon instance, OrbitalX:
   - Copies the default Psiphon config (`/etc/psiphon/psiphon.config`)
   - Updates the config with the target country and assigned ports
   - Starts Psiphon as a systemd service
   - Verifies the service is running properly

### Monitoring

- The systemd service runs the `monitor` command in the background
- Every *N* seconds it checks:
  - Is the process still running? → restart if dead
  - Is the exit IP **reachable**? → if not, rotate (Tor only)
  - After rotation, it verifies the **country match** again (Tor only)
- The active IP is updated whenever it changes

### Integration with Xray

- OrbitalX **does not** modify your Xray config
- After activation, you can see the port via `orbitalx list`
- You manually add a `socks` outbound in your Xray configuration

---

## 🧪 Example Xray Outbound

Once instances are active, add these to your Xray `outbounds` section:

```json
{
  "outbounds": [
    {
      "tag": "DIRECT",
      "protocol": "freedom"
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    },
    {
      "tag": "TR_Tor",
      "protocol": "socks",
      "settings": {
        "port": 9080,
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "US_Psiphon",
      "protocol": "socks",
      "settings": {
        "port": 1093,
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "DE_Tor",
      "protocol": "socks",
      "settings": {
        "port": 9082,
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "DE_Psiphon",
      "protocol": "socks",
      "settings": {
        "port": 1094,
        "address": "127.0.0.1"
      }
    }
  ]
}
```

Then use `"outboundTag": "TR_Tor"` or `"outboundTag": "US_Psiphon"` in your routing rules.

---

## 🛠️ Troubleshooting

### Tor Issues

- **Tor fails to start**: Check `sudo journalctl -u orbitalx-tor-<ID>`
- **Activation fails**: Check `sudo journalctl -u orbitalx-tor-<ID> -n 50 --no-pager`
- **Country mismatch**: Try deactivating and reactivating the location

### Psiphon Issues

- **Psiphon fails to start**: Check `sudo journalctl -u orbitalx-psiphon-<ID>`
- **SOCKS connection fails**: Check if Psiphon tunnel is established in logs
- **Psiphon binary not found**: Run `sudo orbitalx install` to install dependencies

### General

- **Service not running**: `sudo systemctl status orbitalx-monitor`
- **Dialog missing**: `sudo apt install dialog -y`
- **View logs**: Use TUI menu option `5) View Live Logs` or `sudo journalctl -u orbitalx-*`

---

## 🔧 Uninstall

To completely remove OrbitalX from your system:

```bash
sudo orbitalx uninstall
```

You will be asked whether to delete all data directories (`/etc/orbitalx`, `/var/lib/orbitalx`, `/var/log/orbitalx`, `/etc/psiphon-instances`).

---

## 📜 License

MIT – feel free to use and modify.

---

## 🤝 Contributing

Issues and pull requests are welcome. Please keep the code clean and well‑commented.

---

**Happy tunneling!** 🚀