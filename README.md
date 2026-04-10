# DoD/DoW Certificate Installer

Installs U.S. Department of Defense (DoD)/Department of War (DoW)  and affiliated PKI certificates into your system trust store and Firefox. Supports desktop and server Linux distributions, macOS, and common container/cloud images.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/notmayo/dod_certs/main/dod_certs.sh | sudo bash
```

An interactive menu lets you choose which certificate bundles to install. Press **Enter** to install all of them (recommended).

> **Note:** `sudo` is required to write to the system certificate store. On macOS, you will be prompted by the OS rather than needing to prefix with `sudo`.

### Options

| Flag | Description |
|---|---|
| `--roots-only` | Install only self-signed root certificates, skip intermediates |
| `--no-firefox` | Skip Firefox profile import |
| `--no-firefox-policy` | Do not write the Firefox enterprise roots policy |
| `-q, --quiet` | Suppress informational output |
| `-h, --help` | Show help |

---

## Supported Systems

### Linux

| Family | Distributions |
|---|---|
| Debian / Ubuntu | Debian, Ubuntu, Kali, Raspberry Pi OS, Linux Mint, Pop!_OS |
| Fedora / RHEL | Fedora, RHEL, CentOS Stream, Rocky Linux, AlmaLinux, Oracle Linux, CloudLinux |
| Arch | Arch Linux, CachyOS, Manjaro, Garuda, EndeavourOS, Artix |
| openSUSE / SLES | openSUSE Leap, openSUSE Tumbleweed, SLES, SLED |
| Alpine / Wolfi | Alpine Linux, Wolfi (Chainguard) |
| Gentoo | Gentoo, Funtoo, Calculate Linux |
| Photon OS | VMware/Broadcom Photon OS |

### macOS

macOS is supported on both **Intel** and **Apple Silicon** Macs. Certificates are installed into the System Keychain using the built-in `security` command, making them available system-wide.

#### Homebrew

Some optional tools (such as `certutil` for direct Firefox NSS import) require [Homebrew](https://brew.sh) — the standard open-source package manager for macOS. If Homebrew is not installed, the script will offer to install it for you automatically.

> Firefox certificate trust on macOS is handled via an enterprise policy (`ImportEnterpriseRoots`) that reads from the System Keychain, so Homebrew and `certutil` are not required for the common case.

---

## Unsupported Systems

The following systems have immutable root filesystems that prevent persistent changes to the system certificate store. The script will detect these and exit with a message explaining the reason and alternative approach.

| System | Why | Alternative |
|---|---|---|
| Fedora Silverblue / Kinoite / Sericea / Bazzite / Aurora / Bluefin | OSTree-based immutable root | Layer certs via `rpm-ostree` or manage through a container |
| Fedora CoreOS | OSTree-based immutable root | Use Butane/Ignition to inject certs at provision time |
| NixOS | Declarative immutable configuration | Add via `security.pki.certificateFiles` in `configuration.nix` |
| openSUSE MicroOS / Aeon | Immutable root | Not supported |
| SteamOS | Immutable root | Not supported |
| VanillaOS | Immutable root | Use `abroot` |
| Bottlerocket (AWS) | Immutable container host OS | Use SSM or host containers |
| Container-Optimized OS / COS (GCP) | Immutable root | Managed by Google; not supported |
| Flatcar Container Linux | Immutable root | Not supported |

---

## For Sysadmins

### Container Images

The script works inside standard containers. Useful for baking DoD certs into custom base images.

**Tested and supported:**

| Image | Family |
|---|---|
| `debian:latest` | Debian |
| `ubuntu:24.04` | Ubuntu |
| `fedora:latest` | Fedora/RHEL |
| `registry.access.redhat.com/ubi9` | RHEL UBI (enterprise) |
| `amazonlinux:2` | Amazon Linux 2 |
| `amazonlinux:2023` | Amazon Linux 2023 |
| `mcr.microsoft.com/cbl-mariner/base/core:2.0` | Azure Linux (Mariner) |
| `archlinux:latest` | Arch |
| `opensuse/tumbleweed` | openSUSE |
| `alpine:latest` | Alpine |
| `cgr.dev/chainguard/wolfi-base` | Wolfi (Chainguard) |
| `photon:5.0` | VMware Photon OS |

Example — building a custom Debian image with DoD certs baked in:

```dockerfile
FROM debian:latest
RUN apt-get update && apt-get install -y curl sudo ca-certificates
RUN curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/dod_certs.sh \
    | sudo bash -s -- --quiet --no-firefox --no-firefox-policy
```

### Cloud Provider Images

| Provider | Image / OS | Notes |
|---|---|---|
| AWS | Amazon Linux 2 / 2023 | Supported — detected as Fedora/RHEL family |
| AWS | Bottlerocket | **Unsupported** — immutable host OS; use SSM or host containers |
| AWS | Standard AMIs (RHEL, Ubuntu, etc.) | Supported — same as desktop distributions |
| GCP | Container-Optimized OS (COS) | **Unsupported** — immutable; managed by Google |
| GCP | Standard images (Debian, RHEL, etc.) | Supported |
| Azure | Azure Linux / CBL-Mariner | Supported — detected as Fedora/RHEL family |
| Azure | Standard images (Ubuntu, RHEL, etc.) | Supported |
| Oracle Cloud | Oracle Linux | Supported — detected as Fedora/RHEL family |
| VMware / Broadcom | Photon OS | Supported |

### Rancher / Kubernetes

Rancher itself does not have a dedicated OS — worker nodes run standard Linux distributions (RHEL, Ubuntu, SUSE, etc.) which are all supported. The Rancher-specific OSes (RancherOS, K3OS) are end-of-life and not supported. SLE Micro, used by some Rancher edge deployments, is immutable and not supported.

---

## Certificate Bundles

The following bundles are available via the interactive menu. All are sourced directly from [cyber.mil](https://cyber.mil) (smartcard access required).

| # | Bundle | Description |
|---|---|---|
| 1 | DoD/DoW Root | Self-signed root certificates |
| 2 | DoD/DoW Intermediate Trusts | Intermediate CA chain |
| 3 | ECA | External Certification Authority — industry and external partners |
| 4 | JITC | Joint Interoperability Test Command — IT testing and certification |
| 5 | WCF | Web Content Filtering |
| 6 | Federal Agencies | Types 1–2: U.S. federal agencies |
| 7 | Non-federal Issuers | Types 3–4: non-federal issuers |
| 8 | Foreign / Allied / Coalition | Types 5–6: foreign, allied, and coalition partner CAs |

---

## Verification

After running, confirm certificates were installed:

**Linux (Fedora/RHEL/Arch):**
```bash
trust list | grep -i dod | head
```

**Linux (Debian/Ubuntu/SUSE/Gentoo/Photon):**
```bash
ls /etc/ssl/certs | grep -i dod | head
```

**macOS:**
```bash
security find-certificate -a -c "DoD" /Library/Keychains/System.keychain | grep labl
```

**Firefox (all platforms):**
```bash
certutil -L -d sql:"$HOME/.mozilla/firefox/<profile>" | grep -i dod
```
