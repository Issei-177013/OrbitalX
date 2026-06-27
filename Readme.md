# OrbitalX

> **Tor Multi‑Location Manager for Xray**  

OrbitalX is a **bash‑based** tool that runs multiple Tor exit nodes on a single server, each with a **fixed port per country**. It is designed to work alongside **Xray‑core** without touching your Xray configuration – you manually add the outbound using the port and IP that OrbitalX provides.

---

## ✨ Key Features

- **35 predefined countries** with fixed ports (9080–9114)
- **Full country names** displayed in menus
- **Strict country enforcement** – activation fails if no exit node matches the selected country
- **TUI (dialog) menu** for easy interactive management
- **CLI commands** for scripting and automation
- **Available / Active** country lists – activate only what you need
- **Background monitoring** with configurable interval (default 10 minutes)
- **Auto‑rotation** only when IP becomes unreachable (no unnecessary changes)
- **systemd service** integration (install / update / uninstall)
- **No interference** with Xray – you keep full control of your config
- **Automatic migration** – new countries are added to the available list on update

---

## 📦 Installation

### Prerequisites
- Linux (Debian/Ubuntu recommended)
- `tor`, `curl`, `nc`, `ss`, `pgrep`, `pkill`, `dialog`  
  (the installer will prompt you to install missing packages)

---

## 🚀 Quick Start (Run & Install from Menu)

The easiest way to try OrbitalX is to run it directly from the web:

```bash
bash <(curl -sL https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/orbitalx.sh)
```

This will:
- Download the latest script
- Launch the **TUI menu** without installing anything yet  
- From the menu, choose `7) Administration` → `1) Install (full setup)`  
- The script will then install itself as a systemd service, create directories, and start the monitoring daemon.

---

## ⚡ Direct Install (One‑Step)

If you prefer to install immediately without opening the menu first, run:

```bash
bash <(curl -sL https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/orbitalx.sh) install
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

1. Show Available Countries  
2. Activate a Country  
3. Show Active Status  
4. Deactivate a Country  
5. Set Monitor Interval  
6. Stop All Instances  
7. Administration (install / update / uninstall)  
8. Exit  

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
| `update` | Pull latest version from Git (if inside a repo) |
| `add <COUNTRY>` | Activate a country (e.g., `add DE`) |
| `remove <COUNTRY>` | Deactivate a country |
| `status` | Show active locations with ports, IPs, and countries |
| `available` | List countries not yet activated |
| `set-interval <SEC>` | Change monitor interval (in seconds) |
| `monitor` | Run the monitoring daemon (for systemd) |
| `stop-all` | Stop all running Tor instances |
| `help` | Show this help |

#### Examples

```bash
sudo orbitalx add DE        # Activate Germany (port 9080)
sudo orbitalx status        # See active list with full country names
sudo orbitalx remove TR     # Deactivate Turkey
sudo orbitalx set-interval 300  # Monitor every 5 minutes
```

---

## 🗺️ Available Countries (35)

OrbitalX supports the following countries:

- Turkey
- United States
- France
- Austria
- Belgium
- Romania
- Canada
- Singapore
- Japan
- Ireland
- Finland
- Spain
- Poland
- Netherlands
- Italy
- Switzerland
- Sweden
- Norway
- Denmark
- Iceland
- Australia
- India
- Hong Kong
- Ukraine
- Czech Republic
- South Korea
- South Africa
- Mexico
- Malaysia
- Azerbaijan
- Cyprus
- Greece
- Portugal
- Hungary
- Luxembourg

---

## 🗂️ File Structure

| Path | Content |
|------|---------|
| `/etc/orbitalx/available.conf` | Countries not yet activated (`CODE:PORT`) |
| `/etc/orbitalx/active.conf` | Active countries (`CODE:PORT:CONTROL_PORT:IP`) |
| `/etc/orbitalx/monitor_interval.conf` | Monitor interval in seconds |
| `/var/lib/orbitalx/<COUNTRY>/` | Dedicated Tor data directory per country |
| `/var/log/orbitalx/` | Log files (`manager.log`, `tor_DE.log`, …) |
| `/var/run/orbitalx/` | PID files (if needed) |
| `/usr/local/bin/orbitalx` | Main script |
| `/usr/local/bin/VERSION` | Version file |

---

## ⚙️ Configuration

### Fixed Ports Per Country

Ports are automatically assigned starting from **9080** for each country. The exact port for each country can be seen in the TUI menu or by running `orbitalx available`.

### Monitor Interval

Default is **600 seconds (10 minutes)**. You can change it at any time:

```bash
sudo orbitalx set-interval 300   # every 5 minutes
```

The change takes effect immediately (the systemd service is restarted).

---

## 🔄 How It Works

1. **Activation**  
   - When you activate a country, OrbitalX:
     - Removes it from the `available` list.
     - Creates a dedicated `torrc` with `ExitNodes {country}` and `StrictNodes 1`.
     - Starts a Tor daemon on the fixed port.
     - **Verifies the exit IP country** by checking against `ip-api.com`.
     - If the IP does **not** match the requested country, it rotates up to 10 times.
     - If no match is found, **activation fails** and the country remains in the available list.
     - Only when a correct country match is found, the IP is saved in `active.conf`.

2. **Monitoring**  
   - The systemd service runs the `monitor` command in the background.
   - Every *N* seconds it checks:
     - Is the Tor process still running? → restart if dead.
     - Is the exit IP **reachable**? → if not, send `SIGNAL NEWNYM` to rotate.
     - After rotation, it verifies the **country match** again.
     - If the IP country changes unexpectedly, it forces a rotation to restore the correct country.
   - The active IP is updated in `active.conf` whenever it changes, but only if the country is correct.

3. **Integration with Xray**  
   - OrbitalX **does not** modify your Xray config.
   - After activation, you see the port and IP (e.g., `127.0.0.1:9080`).
   - You manually add a `socks` outbound in your Xray configuration, and route traffic to it using your own rules.

---

## 🧪 Example Xray Outbound

Once a country is active (say Germany on port 9080), add this to your Xray `outbounds` section:

```json
{
  "outbounds": [
    {
      "tag": "tor-DE",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 9080
          }
        ]
      }
    }
  ]
}
```

Then use `"outboundTag": "tor-DE"` in your routing rules.

---

## 🛠️ Troubleshooting

- **Tor fails to start**  
  Check the log: `sudo tail -f /var/log/orbitalx/tor_DE.log`  
  Make sure the port is not already in use.

- **Activation fails with "Could not find an exit node in [country]"**  
  This means Tor does not currently have a working exit node in that country. Try again later or choose another country. OrbitalX will **never** fall back to a different country – strict enforcement is by design.

- **Country mismatch in status table**  
  If you see a different country code in the "Country" column than the one you requested, try deactivating and reactivating the location. If the issue persists, Tor may not have a reliable exit node in that country.

- **Service not running**  
  `sudo systemctl status orbitalx`  
  `sudo systemctl restart orbitalx`

- **Dialog missing**  
  The script will attempt to install it automatically. Otherwise:  
  `sudo apt install dialog -y`

---

## 🔧 Uninstall

To completely remove OrbitalX from your system:

```bash
sudo orbitalx uninstall
```

You will be asked whether to delete all data directories (`/etc/orbitalx`, `/var/lib/orbitalx`, `/var/log/orbitalx`).

---

## 📜 License

MIT – feel free to use and modify.

---

## 🤝 Contributing

Issues and pull requests are welcome. Please keep the code clean and well‑commented.

---

**Happy tunneling!** 🚀