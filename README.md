# EasyNFTables

EasyNFTables is an interactive Bash script for installing and managing `nftables` forwarding on Debian servers.

It focuses on a simple menu-driven workflow so you can install `nftables`, add or modify forwarding rules, manage remarks, and apply NAT rules without editing `/etc/nftables.conf` by hand.

## Features

- Install and initialize `nftables`
- Add, modify, view, and delete forwarding rules
- Validate IPv4 addresses and ports before writing rules
- Add remarks for each forwarding rule
- Optional source whitelist for local inbound and forwarded traffic
- Select province/city IP ranges from bundled offline data
- Add manual IP/CIDR whitelist entries, with current SSH IP protection
- Generate `/etc/nftables.conf` in a tutorial-style layout with comments
- Shortcut command `nf`

## Usage

```bash
bash <(curl -Ls https://raw.githubusercontent.com/DarkJimiHole/easynftables/main/install.sh)
```

## Menu

```text
1. 安装nftables
2. 查看转发
3. 添加转发
4. 修改转发
5. 删除转发
6. 白名单管理
7. 卸载
0. 退出脚本
```

## Whitelist

The whitelist module can restrict new local inbound and forwarded connections by source IP.

- Manual whitelist entries are saved in `/etc/nft-forward/manual_whitelist.list`
- Selected province/city codes are saved in `/etc/nft-forward/region_whitelist.codes`
- Generated nftables set files are stored under `/etc/nft-forward/sets/`
- When enabling whitelist restrictions, the current SSH client IPv4 is automatically added to the manual whitelist
- Region whitelist data is bundled under `data/` and parsed by `tools/region_tool.py`

Whitelist matching order:

```text
manual whitelist -> region whitelist, if enabled -> reject
```

Region whitelist sources are disabled by default. You can select regions first and enable the region source later.

## What The Script Manages

- shortcut command: `/usr/local/bin/nf`
- compatibility shortcut: `/usr/local/sbin/nf`
- config directory: `/etc/nft-forward`
- rule database: `/etc/nft-forward/forwards.db`
- config file: `/etc/nft-forward/config.env`
- whitelist files: `/etc/nft-forward/manual_whitelist.list`, `/etc/nft-forward/region_whitelist.codes`
- whitelist nft set files: `/etc/nft-forward/sets/*.nft`
- generated nft config: `/etc/nftables.conf`
- sysctl file: `/etc/sysctl.d/99-nft-forward.conf`

## Notes

- This repository stores the script as `install.sh`, while the installed runtime command is `nf`.
- The script writes DNAT, SNAT, and MSS rules based on the forwarding entries you configure.
- Rule remarks are shown in the menu and written into the generated nftables config as comments.

## License

Use at your own risk.
