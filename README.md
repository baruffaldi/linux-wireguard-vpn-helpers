# 🎛️ VPN Helpers (WireGuard)

**A robust, sysadmin-friendly toolkit to prepare an Alpine Linux host and fully manage a WireGuard® VPN server, clients, and optional IP-based ACL filtering.**
It provides interactive configurators, safe defaults, portability across BusyBox/regular shells, and a tiny built-in “microserver” to distribute client configs.

> **Flow at a glance**
>
> 1. `sys_prepare_alpinelinux.sh` → prepare Alpine Linux base (packages, services)
> 2. `wg_server_configure.sh` → initialize and configure the WireGuard server
> 3. `wg_client_configure.sh` → add/update/delete clients, generate configs, share via microserver
> 4. *(optional)* `wg_filter_configure.sh` → enable an iptables-based ACL for your WG UDP port

---

## ✨ Highlights

* **Alpine-first**: turn a fresh Alpine machine into a ready WireGuard box in minutes.
* **One-shot server bootstrap**: interactive **server** configurator with smart IP math, range calculation, key management, and resilient config writing.
* **Powerful client manager**:

  * Creates clients with deterministic addressing (next-free client slot)
  * Regenerates keys/configs on demand
  * Renames clients safely (renames files and updates server config)
  * Removes clients cleanly (purges files **and** server peer block)
  * Shares `.conf` files via a **microserver** (fallback chain: `python3 -m http.server` → `darkhttpd` → `busybox-httpd` → `httpd`)
* **Optional ACL filter**: `iptables` chain that **only** allows WG UDP from:

  * DNS-resolved dynamic hostnames (DDNS)
  * An external URL with additional IP/CIDR entries
  * Everything else to the WG port is **dropped**
* **BusyBox compatible**, careful with quoting/whitespace, and defensive in error handling.

---

## 📦 What’s inside (file-by-file)

### `sys_prepare_alpinelinux.sh`

Prepares an Alpine Linux system for the rest of the tooling.

**What it does**

* Updates and upgrades the system with `apk update && apk upgrade`.
* Detects if running on a **VM** (searches for hypervisor markers in `/proc/cpuinfo` or DMI) to optionally install VMware guest tools:

  * `open-vm-tools`, `open-vm-tools-guestinfo`, `open-vm-tools-deploypkg`.
* Installs core packages:

  * `wireguard-tools`, `iptables`, `openrc`, `darkhttpd`, `iptables-openrc`.
* Ensures services are enabled for the default runlevel:

  * `rc-update add iptables default`
  * `rc-update add networking default`

> **Notes**
>
> * This script is Alpine-specific by design. See **Contributing** below for adding other distros.

---

### `wg_server_configure.sh`

Interactive WireGuard **server** configurator. Creates a durable `wg0` setup (or another interface name you pass as `$1`) with proper key management and safe config writing.

**Key behaviors & features**

* **Interface awareness**: works on `wg0` by default; override with `./wg_server_configure.sh wg1`.
* **WireGuard paths**:

  * `WG_DIR=/etc/wireguard`
  * `WG_CONF=/etc/wireguard/<iface>.conf`
  * Keeps server keys at:

    * `server_private.key`
    * `server_public.key`
* **Metadata comments in `wg0.conf`**:

  * The script writes helpful `#` comments such as:

    * `# PublicKey: <…>`
    * `# Endpoint: <host:port>`
    * `# Subnet: <A.B.C.D/nn>`
  * These are later parsed by the client manager to avoid duplication of inputs.
* **CIDR and ranges**:

  * Accepts your **server IP** and **netmask bits**, computes:

    * `Address = <server_ip>/<mask>`
    * `SUBNET = <base>/<mask>`
    * `VPN_RANGE_NET` and **client range** string for clarity
* **Port/endpoint/DNS**:

  * Interactively asks for ListenPort, Endpoint (FQDN or pub IP + port), and optional DNS for clients.
* **Existing peers preservation**:

  * If a previous `wg0.conf` exists, it saves existing `[Peer]` blocks and merges them back after rewriting the `[Interface]` block — preventing peer loss.
* **Key generation**:

  * If server keys are missing, generates fresh ones with `wg genkey | tee … | wg pubkey`.
* **Apply changes**:

  * Brings interface up with `wg-quick up <iface>` (stops first if already up).
* **Final summary**:

  * Prints a digest: `Address`, `Subnet`, ranges, `Port`, `Endpoint`, and **max clients** considered by the addressing math.

---

### `wg_client_configure.sh`

An interactive **client** manager for WireGuard. It reads the server configuration and helps you **create**, **update**, **rename**, **delete**, **regenerate**, and **export** client configurations.

**Core concepts**

* **Server introspection**: reads from server `wg0.conf` comments and keys:

  * `# Subnet: …` → used to compute client IPs
  * `# PublicKey: …` → server’s pubkey
  * `# Endpoint: …` → `<host:port>` for client `[Peer]`
  * `DNS = …` (if provided in server file)
* **Directories & naming**

  * Uses `/etc/wireguard/clients` as the canonical storage for client artifacts:

    * `client<N>_<Name>_secret.key`
    * `client<N>_<Name>_public.key`
    * `client<N>_<Name>_config.conf` (the file you share)
* **Deterministic addressing**

  * Computes the **next free client number** (`next_free_client_number`), then assigns:

    * `client<N>_<Name>`
    * IP as `BASE3.(1+N)` or via `calc_client_ip(SUBNET,N)` (consistent, avoids overlap)
* **Generate client config**

  * Writes a minimal, compatible `[Interface]` for the client with:

    * `Address = <client_ip>/<mask>`
    * `DNS = <server_dns>` (if any)
  * Adds a `[Peer]` with:

    * `PublicKey = <server_pubkey>`
    * `Endpoint = <endpoint>`
    * `AllowedIPs`:

      * One line with `ip/32` (client self)
      * One line with `office subnets` (**prompted** per client; multiple CIDRs comma-separated)
    * `PersistentKeepalive = 25`
* **Append / Remove server peers**

  * Appends a peer block to server `wg0.conf` with:

    * `# NAME: client<N>_<Name>` as a header comment
    * `PublicKey = <client_pubkey>`
    * `AllowedIPs = <client_ip>/32`
  * Can remove the peer block when deleting a client (`server_remove_peer_block`).
* **Update clients**

  * Change **name**, **IP**, **office subnets**, optionally **regenerate keys**.
  * Safely updates file names and the corresponding server peer block.
  * Rewrites the `.conf` for the client accordingly.
* **Delete clients**

  * Confirms deletion, then:

    * Removes `client<N>_<Name>_*` files
    * Removes matching `[Peer]` block from the server config
* **Microserver (share configs easily)**

  * Generates a simple HTML index in the clients directory and serves it on a chosen IP:PORT.
  * **Fallback chain** (whichever exists is used):

    1. `python3 -m http.server`
    2. `darkhttpd`
    3. `busybox-httpd` (`httpd`)
    4. `httpd`
  * Creates a dedicated temporary area, **auto-stop link** (`/stop`) and a **5-minute auto-stop** guard.
  * Shows the bind IPs available (via `ip` or `ifconfig`).
  * Useful when you want a **one-click download** of `.conf` from a phone or laptop.

> **Safety**
> The script is strict (`set -eu`), checks for root privileges where needed, and validates that `wg` is installed (will ask what package manager you use if missing: `apk/apt/yum/dnf/zypper/pacman/opkg`).

---

### `wg_filter_configure.sh`

Interactive configurator for the **optional ACL** that restricts which **source IPs** are allowed to hit your **WireGuard UDP port**.

**What it writes**

* A `wg_filter.conf` (or you can start from `wg_filter.conf.example`) with:

  * `WGPORT="<udp_port>"` — your WireGuard UDP port
  * `WAN_IF="eth0"` — the WAN interface of your machine
  * `HOSTS="ddns.example.com another.example.net"` — one or more DDNS hostnames to **resolve to A records** (IPs are allowed)
  * `EXTRA_URL="https://example.com/acl.txt"` — URL of a **plain-text allowlist** (one IP or CIDR per line)
  * `IPTABLES="/usr/sbin/iptables"` — path to iptables binary
  * `CHAIN="WG_FILTER"` — dedicated iptables chain name
* Installs a **crontab line** that runs `wg_filter.sh` **every minute**:

  ```
  * * * * * /path/to/repo/wg_filter.sh >/dev/null 2>&1
  ```

  *(It uses the absolute path of your cloned folder; on Alpine you may want `rc-service crond reload` afterward.)*

**Lifecycle**

* If a prior config exists, it can be removed first on user confirmation.
* Shows your current values in brackets as defaults for a smooth update experience.

---

### `wg_filter.sh`

The actual **enforcement** script (called by cron). It builds and applies an iptables chain that allows only the permitted sources to your WG UDP port.

**How it works**

1. **Load config** from `wg_filter.conf` (`. ./wg_filter.conf`). Ensures critical variables like `WGPORT` are set.
2. **Resolve hostnames** listed in `HOSTS` using `dig +short A <host>` → a set of **A record** addresses.
3. **Fetch extra allowlist** from `EXTRA_URL` with `curl -fsS` → read lines as IP or CIDR.
4. **Merge and deduplicate** (`sort -u`) to produce the final `ALLOW_LIST`.
5. **Program iptables:**

   * Ensure a dedicated chain exists (default `WG_FILTER`).
   * Ensure there’s an **INPUT jump** for `-i <WAN_IF> -p udp --dport <WGPORT>` to that chain.
   * **Flush** the chain and **append** `-s <IP|CIDR> -j ACCEPT` for each source.
   * Finally **`-j DROP`** for any other source hitting the WG port.
6. **Persist on Alpine**: if `/etc/init.d/iptables` exists, runs `save`.

**Outcome**

* You get a tight, self-healing ACL: when your DDNS changes or your allowlist URL updates, the iptables set adjusts automatically (cron-driven).

---

## 🚀 Quickstart

0. **Installation (tested only on Alpine Linux)**
```sh
wget -qO- https://studio.baruffaldi.info/dl/vpn-wg | sh 
```

> Assumes Alpine Linux. For other distros, see **Contributing**—PRs very welcome!

1. **Prepare the system (Alpine)**

```sh
sudo ./sys_prepare_alpine.sh
```

2. **Configure the server**

```sh
sudo ./wg_server_configure.sh        # or pass another interface name as argument
```

You’ll be asked for **interface IP/subnet**, **ListenPort**, **Endpoint**, and optional **DNS** for clients. Existing `[Peer]` blocks are preserved.

3. **Manage clients**

```sh
sudo ./wg_client_configure.sh
```

* Create new clients, update or delete existing ones.
* The script reads server metadata from `wg0.conf` comments, computes IPs, and appends/removes server peers accordingly.
* To **share** client configs, use the menu entry “Start microserver,” choose **bind IP** and port, and let end-users download their `.conf`.

4. *(Optional)* **Enable ACL filtering**

```sh
sudo ./wg_filter_configure.sh
```

* Fill in `WGPORT`, `WAN_IF`, one or more `HOSTS` (DDNS), and an `EXTRA_URL` with IPs/CIDRs (one per line).
* The configurator writes `wg_filter.conf` and adds a **crontab** entry to run `wg_filter.sh` every minute.
* Verify: `sudo ./wg_filter.sh` (manual run) and then try to reach the WG UDP port from allowed vs. non-allowed sources.

---

## 🧩 Design details & safety

* **Strict shell**: all scripts start with `set -eu`.
* **Portability**: favors POSIX tools; compatible with BusyBox utilities on Alpine.
* **Idempotent**:

  * Server configurator **preserves** existing `[Peer]` blocks.
  * Client manager **never** trashes peers silently; it updates or removes them explicitly.
* **Traceable metadata**: `# PublicKey`, `# Endpoint`, `# Subnet`, and per-peer `# NAME:` comments make the files **self-documenting** and machine-readable.
* **Security**:

  * Client keys are generated per client (`wg genkey` / `wg pubkey`).
  * Client directories are kept in `/etc/wireguard/clients` with strict modes on secrets.
  * Optional ACL filter drops non-allowlisted sources at the **first hop** (INPUT chain).

---

## 📚 Usage tips

* To switch interface: pass it to the server script, e.g. `./wg_server_configure.sh wg1`, then always run the client manager with the same `INTERFACE` argument if you extend it to support `$1`.
* To add multiple office networks to a client, answer with comma-separated CIDRs (e.g., `192.168.10.0/24,10.0.0.0/24`).
* Microserver index lives in the clients directory; it lists available `*.conf` ready to download.
* On Alpine, remember to **persist iptables** (the scripts do this when possible).

---

## 🧪 Troubleshooting

* **`wg` not found**
  The client script detects the package manager and guides installation (`apk/apt/yum/dnf/zypper/pacman/opkg`). On Alpine, make sure `wireguard-tools` is installed.

* **Interface won’t come up**
  Check `/etc/wireguard/<iface>.conf` syntax and that the server has a valid keypair. The server script will generate keys if missing.

* **Clients can’t reach LAN**
  Ensure the client’s `AllowedIPs` includes the relevant office subnets (comma-separated) and server routing/NAT is configured appropriately.

* **ACL blocks everyone**
  Confirm `HOSTS` resolve to valid public IPs and `EXTRA_URL` serves a plain text list of IP/CIDR (one per line). Run `./wg_filter.sh` manually to see the applied chain and log output.

---

## 🤝 Contributing

This toolkit is **Alpine-first** out of the box.
If you’d like to support **other distributions** (Debian/Ubuntu, RHEL/CentOS/Alma, Fedora, Arch, OpenWrt, etc.), PRs are **very welcome**:

* Add a `sys_prepare_<distro>.sh` to mirror Alpine’s behavior (packages, services).
* Keep scripts **POSIX-ish** and BusyBox-friendly when feasible.
* Maintain the metadata comments in configs—other scripts rely on them.
* If you improve the microserver fallback chain (e.g., add `caddy` or `nginx` options) or extend client menu actions, document them in this `README`.

**Coding style**: shellcheck-aware, careful quoting, no unguarded `rm -rf`, and explicit error handling with clear messages.

---

## 📄 License

WireGuard® is a registered trademark of Jason A. Donenfeld.  
This project is open source and distributed under the terms of the [MIT License](LICENSE).

---

## 🧭 Repository map

```
.
├── sys_prepare_alpinelinux.sh      # Prepare Alpine system (packages, services)
├── wg_server_configure.sh          # Interactive WireGuard server configurator
├── wg_client_configure.sh          # Client manager (create/update/delete/export)
├── wg_filter_configure.sh          # Interactive ACL setup (writes config + cron)
├── wg_filter.sh                    # Enforces iptables ACL for WG UDP port
├── wg_filter.conf.example          # Example ACL config
└── wg_filter.conf                  # (Optional) Your live ACL config
```

---

## 📝 Appendix: Configuration artifacts

* **Server**: `/etc/wireguard/<iface>.conf`

  * Comments:

    * `# PublicKey: <server_pubkey>`
    * `# Endpoint: <host:port>`
    * `# Subnet: <base/mask>`
  * Preserves `[Peer]` blocks across re-runs.

* **Clients**: `/etc/wireguard/clients`

  * `client<N>_<Name>_secret.key`
  * `client<N>_<Name>_public.key`
  * `client<N>_<Name>_config.conf`

* **ACL**:

  * `wg_filter.conf`
  * Cron entry: `* * * * * /absolute/path/wg_filter.sh >/dev/null 2>&1`
  * iptables chain: `WG_FILTER` (customizable)

---

**Enjoy!** If this toolkit saves you time, consider sharing improvements with a PR so others benefit too.
