#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s nullglob

# ── Bundle catalogue ───────────────────────────────────────────────────────────

BUNDLE_LABELS=(
  "DoD/DoW Root"
  "DoD/DoW Intermediate Trusts"
  "DoD/DoW ECA  (External Certification Authority – industry/external partners)"
  "DoD/DoW JITC (Joint Interoperability Test Command – IT testing & certification)"
  "DoD/DoW WCF  (Web Content Filtering)"
  "DoD/DoW Federal Agencies (Types 1–2)"
  "DoD/DoW Non-federal Issuers (Types 3–4)"
  "DoD/DoW Foreign / Allied / Coalition / Other (Types 5–6)"
)

BUNDLE_URLS=(
  "https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_DoD.zip"
  "https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-dod_approved_external_pkis_trust_chains.zip"
  "https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_ECA.zip"
  "https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_JITC.zip"
  "https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_WCF.zip"
  "https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-dod_approved_external_pkis_trust_chains_types_1-2_federal_agencies.zip"
  "https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-dod_approved_external_pkis_trust_chains_types_3-4_non_federal_issuers.zip"
  "https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-dod_approved_external_pkis_trust_chains_types_5-6_foreign_other.zip"
)

# Populated by select_bundles(); not intended to be edited directly.
ZIP_URLS=()
ZIP_LABELS=()

MIN_CERTS=20   # Sanity floor: fewer than this likely indicates a bad or truncated download

ROOTS_ONLY=0
IMPORT_FIREFOX=1
ENABLE_FIREFOX_POLICY=1
QUIET=0

# ── Logging ────────────────────────────────────────────────────────────────────

log()  { [[ "$QUIET" -eq 1 ]] || echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[x] $*" >&2; exit 1; }

# ── Usage ──────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: dod_certs.sh [options]

Options:
  --roots-only              Keep only self-signed roots before installing/importing
  --no-firefox              Skip Firefox profile import
  --no-firefox-policy       Do not create Firefox enterprise roots policy
  -q, --quiet               Less output
  -h, --help                Show this help
EOF
}

# ── Argument parsing ───────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --roots-only)        ROOTS_ONLY=1;           shift ;;
    --no-firefox)        IMPORT_FIREFOX=0;        shift ;;
    --no-firefox-policy) ENABLE_FIREFOX_POLICY=0; shift ;;
    -q|--quiet)          QUIET=1;                 shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die "Unknown option: $1" ;;
  esac
done

# ── Bundle selection menu ──────────────────────────────────────────────────────

select_bundles() {
  local n=${#BUNDLE_LABELS[@]}
  local -a sel
  for (( i=0; i<n; i++ )); do sel[i]=1; done   # default: all selected

  # Non-interactive or quiet → silently use all bundles.
  if [[ "$QUIET" -eq 1 ]] || [[ ! -t 0 ]]; then
    ZIP_URLS=("${BUNDLE_URLS[@]}")
    ZIP_LABELS=("${BUNDLE_LABELS[@]}")
    return 0
  fi

  draw_menu() {
    echo ""
    echo "  ┌─ Certificate bundles ────────────────────────────────────────────────┐"
    for (( i=0; i<n; i++ )); do
      local mark=" "
      [[ "${sel[i]}" -eq 1 ]] && mark="x"
      printf "  │  [%s] %d. %s\n" "$mark" "$(( i+1 ))" "${BUNDLE_LABELS[i]}"
    done
    echo "  │"
    echo "  │  [x] 9. All  (default)"
    echo "  └──────────────────────────────────────────────────────────────────────┘"
    echo "  Toggle by number(s) (e.g. 3 5), 'a' = all, 'n' = none, Enter = confirm:"
    printf "  > "
  }

  while true; do
    draw_menu
    local input
    IFS= read -r input </dev/tty
    case "$input" in
      "")
        break
        ;;
      a|A|9)
        for (( i=0; i<n; i++ )); do sel[i]=1; done
        ;;
      n|N)
        for (( i=0; i<n; i++ )); do sel[i]=0; done
        ;;
      *)
        for token in $input; do
          if [[ "$token" =~ ^[1-8]$ ]]; then
            local idx=$(( token - 1 ))
            sel[idx]=$(( 1 - sel[idx] ))
          else
            echo "  [!] Ignored unrecognised input: $token"
          fi
        done
        ;;
    esac
  done

  ZIP_URLS=()
  ZIP_LABELS=()
  for (( i=0; i<n; i++ )); do
    if [[ "${sel[i]}" -eq 1 ]]; then
      ZIP_URLS+=("${BUNDLE_URLS[i]}")
      ZIP_LABELS+=("${BUNDLE_LABELS[i]}")
    fi
  done

  (( ${#ZIP_URLS[@]} > 0 )) || die "No bundles selected — nothing to do."

  echo ""
  log "Selected ${#ZIP_URLS[@]} bundle(s):"
  for label in "${ZIP_LABELS[@]}"; do
    log "  • $label"
  done
  echo ""
}

select_bundles

# ── OS detection ───────────────────────────────────────────────────────────────

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Immutable/atomic systems have read-only /usr or /etc and no supported package
# manager for persistent CA installs — detect and bail out early.
reject_immutable() {
  [[ -r /etc/os-release ]] || return 0
  . /etc/os-release
  local id="${ID:-}" like="${ID_LIKE:-}" variant="${VARIANT_ID:-}"

  # OSTree-booted systems (Silverblue, Kinoite, Bazzite, Aurora, Bluefin, CoreOS…)
  if [[ -e /run/ostree-booted ]]; then
    die "OSTree-based immutable system detected (${PRETTY_NAME:-$id}). \
CA trust changes must be layered via 'rpm-ostree' or managed through a container — not supported."
  fi

  # Known immutable distros by ID
  case "$id" in
    nixos)
      die "NixOS detected. Add certs via 'security.pki.certificateFiles' in configuration.nix — not supported here." ;;
    flatcar)
      die "Flatcar Container Linux detected. Immutable root — not supported." ;;
    vanillaos)
      die "VanillaOS detected. Use 'abroot' to manage system packages — not supported." ;;
    opensuse-microos|opensuse-aeon)
      die "openSUSE MicroOS/Aeon detected. Immutable root — not supported." ;;
    steamos)
      die "SteamOS detected. Immutable root — not supported." ;;
    bottlerocket)
      die "Bottlerocket (AWS) detected. Immutable container host — manage certs via host containers or SSM — not supported." ;;
    cos)
      die "Container-Optimized OS (GCP) detected. Immutable root — not supported." ;;
  esac

  # Atomic/immutable variant IDs (e.g. Fedora spins that share ID=fedora)
  case "$variant" in
    silverblue|kinoite|sericea|onyx|coreos|iot)
      die "Immutable Fedora variant '${variant}' detected (${PRETTY_NAME:-$id}). \
Layer certs via 'rpm-ostree install' — not supported here." ;;
  esac
}

detect_os_family() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macos"
    return 0
  fi

  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release. Unsupported platform."
  . /etc/os-release
  local id="${ID:-}" like="${ID_LIKE:-}"

  if   [[ "$id" =~ (fedora|rhel|centos|rocky|almalinux|ol) ]] || [[ "$like" =~ (fedora|rhel) ]]; then
    echo "rhel"
  elif [[ "$id" =~ (debian|ubuntu|linuxmint|pop|kali|raspbian) ]] || [[ "$like" =~ (debian|ubuntu) ]]; then
    echo "debian"
  elif [[ "$id" =~ (arch|endeavouros|manjaro|garuda|artix) ]]    || [[ "$like" =~ arch ]]; then
    echo "arch"
  elif [[ "$id" =~ (opensuse|sles|sled) ]]                       || [[ "$like" =~ (suse|opensuse) ]]; then
    echo "suse"
  elif [[ "$id" == "alpine" || "$id" == "wolfi" ]]; then
    echo "alpine"
  elif [[ "$id" =~ (gentoo|funtoo|calculate) ]]                  || [[ "$like" =~ gentoo ]]; then
    echo "gentoo"
  elif [[ "$id" == "photon" ]]; then
    echo "photon"
  else
    die "Unsupported distro '${id}'. Supported families: Alpine/Wolfi, Arch, Debian/Ubuntu, Fedora/RHEL, Gentoo, macOS, openSUSE/SLES, Photon OS."
  fi
}

reject_immutable
OS_FAMILY="$(detect_os_family)"

# ── Distro-specific configuration ─────────────────────────────────────────────

case "$OS_FAMILY" in
  arch)
    ANCHORS_DIR="/etc/ca-certificates/trust-source/anchors"
    UPDATE_TRUST_CMD=(sudo update-ca-trust)
    PKG_INSTALL_CMD=(sudo pacman -Sy --needed --noconfirm)
    ;;
  debian)
    ANCHORS_DIR="/usr/local/share/ca-certificates"
    UPDATE_TRUST_CMD=(sudo update-ca-certificates)
    PKG_INSTALL_CMD=(sudo apt-get install -y)
    ;;
  rhel)
    ANCHORS_DIR="/etc/pki/ca-trust/source/anchors"
    UPDATE_TRUST_CMD=(sudo update-ca-trust)
    if need_cmd dnf; then
      PKG_INSTALL_CMD=(sudo dnf install -y)
    elif need_cmd yum; then
      PKG_INSTALL_CMD=(sudo yum install -y)
    else
      die "Neither dnf nor yum found."
    fi
    ;;
  suse)
    ANCHORS_DIR="/etc/pki/trust/anchors"
    UPDATE_TRUST_CMD=(sudo update-ca-certificates)
    PKG_INSTALL_CMD=(sudo zypper install -y)
    ;;
  alpine)
    ANCHORS_DIR="/usr/local/share/ca-certificates"
    UPDATE_TRUST_CMD=(sudo update-ca-certificates)
    PKG_INSTALL_CMD=(sudo apk add)
    ;;
  gentoo)
    ANCHORS_DIR="/usr/local/share/ca-certificates"
    UPDATE_TRUST_CMD=(sudo update-ca-certificates)
    PKG_INSTALL_CMD=(sudo emerge -q)
    ;;
  photon)
    ANCHORS_DIR="/etc/ssl/certs"
    UPDATE_TRUST_CMD=(sudo update-ca-certificates)
    PKG_INSTALL_CMD=(sudo tdnf install -y)
    ;;
  macos)
    # Certs go directly into the System Keychain via `security`; no anchor dir.
    ANCHORS_DIR=""
    UPDATE_TRUST_CMD=()
    if need_cmd brew; then
      PKG_INSTALL_CMD=(brew install)
    else
      PKG_INSTALL_CMD=()
    fi
    ;;
esac

# ── Package management ─────────────────────────────────────────────────────────

# Returns the distro-specific package name for a logical tool name.
pkg_for() {
  local tool="$1"
  case "$tool" in
    python3)
      case "$OS_FAMILY" in
        arch)   echo "python"  ;;
        alpine) echo "python3" ;;
        *)      echo "python3" ;;
      esac
      ;;
    certutil)
      case "$OS_FAMILY" in
        debian) echo "libnss3-tools"     ;;
        arch)   echo "nss"               ;;
        rhel)   echo "nss-tools"         ;;
        suse)   echo "mozilla-nss-tools" ;;
        alpine) echo "nss-tools"         ;;
        gentoo)  echo "dev-libs/nss"      ;;
        photon)  echo "nss-tools"        ;;
        macos)   echo "nss"              ;;  # brew install nss
      esac
      ;;
    unzip)
      # Alpine splits unzip into its own package; others use the same name.
      echo "unzip"
      ;;
    *) echo "$tool" ;;
  esac
}

ensure_homebrew() {
  need_cmd brew && return 0

  warn "Homebrew is not installed — it is needed to fetch missing tools."

  local answer="y"
  if [[ -t 0 && "$QUIET" -eq 0 ]]; then
    printf "  Install Homebrew now? [Y/n] "
    IFS= read -r answer </dev/tty
    answer="${answer:-y}"
  fi

  case "$answer" in
    y|Y|"")
      log "Installing Homebrew..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "Homebrew installation failed. Install it manually from https://brew.sh and re-run."
      # Add brew to PATH for the remainder of this session.
      if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
      fi
      PKG_INSTALL_CMD=(brew install)
      ;;
    *)
      die "Homebrew is required to install missing tools. Install it from https://brew.sh and re-run."
      ;;
  esac
}

ensure_packages() {
  # curl, unzip, and openssl are all built-in on macOS — only check optional tools.
  local check_tools=(curl unzip openssl python3 certutil)
  local builtin_on_macos=(curl unzip openssl)

  local missing=()
  for tool in "${check_tools[@]}"; do
    if need_cmd "$tool"; then
      continue
    fi
    if [[ "$OS_FAMILY" == "macos" ]]; then
      local is_builtin=0
      for b in "${builtin_on_macos[@]}"; do [[ "$b" == "$tool" ]] && is_builtin=1 && break; done
      (( is_builtin )) && continue  # shouldn't be missing, but skip gracefully
      if (( ${#PKG_INSTALL_CMD[@]} == 0 )); then
        ensure_homebrew
      fi
    fi
    missing+=("$(pkg_for "$tool")")
  done

  (( ${#missing[@]} == 0 )) && return 0

  log "Installing missing packages: ${missing[*]}"
  [[ "$OS_FAMILY" == "debian" ]] && sudo apt-get update -q
  "${PKG_INSTALL_CMD[@]}" "${missing[@]}"
}

ensure_packages

# ── Working directory ──────────────────────────────────────────────────────────

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log "Workdir: $WORKDIR"
cd "$WORKDIR"

# ── Download + extract ─────────────────────────────────────────────────────────

download_and_extract() {
  local url="$1" index="$2" label="$3"
  local fname="bundle_${index}.zip"
  local outdir="bundle_${index}"
  mkdir -p "$outdir"

  log "Downloading ($((index+1))/${#ZIP_URLS[@]}): $label"

  local -a curl_opts=(
    --fail --location
    --connect-timeout 15
    --max-time 300
    --retry 3
    --retry-delay 2
  )
  # Show a progress bar on an interactive terminal; stay silent otherwise.
  if [[ -t 1 && "$QUIET" -eq 0 ]]; then
    curl_opts+=(--progress-bar)
  else
    curl_opts+=(-s)
  fi

  curl "${curl_opts[@]}" --output "$fname" "$url" \
    || die "Download failed: $label"

  [[ -s "$fname" ]] || die "Empty file after download: $label"

  log "Extracting: $fname"
  unzip -oq "$fname" -d "$outdir"
}

for i in "${!ZIP_URLS[@]}"; do
  download_and_extract "${ZIP_URLS[i]}" "$i" "${ZIP_LABELS[i]}"
done

# ── Certificate normalization ──────────────────────────────────────────────────

: > combined.pem

extract_pem_der_certs() {
  find bundle_* -type f \( -iname '*.pem' -o -iname '*.crt' -o -iname '*.cer' \) -print0 \
  | while IFS= read -r -d '' f; do
      if grep -q "BEGIN CERTIFICATE" "$f" 2>/dev/null; then
        awk 'BEGIN{p=0} /BEGIN CERTIFICATE/{p=1} p; /END CERTIFICATE/{p=0}' "$f" \
          >> combined.pem || true
      else
        openssl x509 -inform DER -in "$f" -outform PEM >> combined.pem 2>/dev/null || true
      fi
    done
}

extract_pkcs7_certs() {
  find bundle_* -type f \( -iname '*.p7b' -o -iname '*.p7c' \) -print0 \
  | while IFS= read -r -d '' f; do
      if grep -q "BEGIN PKCS7" "$f" 2>/dev/null; then
        openssl pkcs7 -inform PEM -print_certs -in "$f" >> combined.pem 2>/dev/null || true
      else
        openssl pkcs7 -inform DER -print_certs -in "$f" >> combined.pem 2>/dev/null || true
      fi
    done
}

extract_pem_der_certs
extract_pkcs7_certs

[[ -s combined.pem ]] || die "combined.pem is empty — no certificates were extracted"

# ── Deduplication ──────────────────────────────────────────────────────────────

log "Splitting and deduplicating certificates..."
python3 - <<'PY'
import pathlib, re, subprocess

data = pathlib.Path("combined.pem").read_text(encoding="utf-8", errors="ignore")
blocks = re.findall(
    r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----",
    data,
    re.DOTALL,
)

out = pathlib.Path("named")
out.mkdir(parents=True, exist_ok=True)

seen = set()

for i, block in enumerate(blocks):
    tmp = pathlib.Path("tmp.pem")
    tmp.write_text(block)
    result = subprocess.run(
        ["openssl", "x509", "-in", str(tmp), "-noout", "-fingerprint", "-sha256"],
        capture_output=True, text=True,
    )
    fp = result.stdout.strip()

    if fp and "=" in fp:
        fp = fp.split("=", 1)[1].replace(":", "")
    else:
        fp = f"UNKNOWN{i:04d}"

    if fp not in seen:
        seen.add(fp)
        (out / f"dod_{fp}.crt").write_text(block)

    tmp.unlink(missing_ok=True)

print(len(seen))
PY

count_named() {
  find named -maxdepth 1 -type f -name 'dod_*.crt' | wc -l | tr -d ' '
}

CERT_COUNT="$(count_named)"
log "Prepared $CERT_COUNT unique certificate file(s)."

(( CERT_COUNT >= MIN_CERTS )) \
  || die "Only $CERT_COUNT certs found after dedup — expected at least $MIN_CERTS. Download may be corrupt or truncated."

# ── Roots-only filter ──────────────────────────────────────────────────────────

filter_to_roots() {
  log "Filtering to self-signed roots..."
  mkdir -p roots

  local f sub iss
  for f in named/*.crt; do
    sub="$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 2>/dev/null || true)"
    iss="$(openssl x509 -in "$f" -noout -issuer  -nameopt RFC2253 2>/dev/null || true)"
    [[ -n "$sub" && "$sub" == "$iss" ]] && cp -- "$f" roots/
  done

  rm -f named/*.crt
  compgen -G "roots/*.crt" > /dev/null && mv roots/*.crt named/

  log "Roots kept: $(count_named)"
}

[[ "$ROOTS_ONLY" -eq 1 ]] && filter_to_roots

# ── System trust install ───────────────────────────────────────────────────────

install_system_certs() {
  if [[ "$OS_FAMILY" == "macos" ]]; then
    log "Installing to macOS System Keychain..."
    local f count=0
    for f in named/*.crt; do
      sudo security add-trusted-cert -d -r trustRoot \
        -k /Library/Keychains/System.keychain "$f" 2>/dev/null \
        || warn "Failed to add $(basename "$f") to System Keychain"
      (( count += 1 ))
    done
    log "Added $count certificate(s) to System Keychain."
    return 0
  fi

  log "Installing to system trust: $ANCHORS_DIR"
  sudo mkdir -p "$ANCHORS_DIR"

  for f in named/*.crt; do
    sudo cp -f -- "$f" "$ANCHORS_DIR/"
  done

  log "Updating system CA trust..."
  "${UPDATE_TRUST_CMD[@]}"
}

# ── Firefox enterprise policy ──────────────────────────────────────────────────

firefox_policy_dirs() {
  if [[ "$OS_FAMILY" == "macos" ]]; then
    cat <<'EOF'
/Library/Application Support/Mozilla/policies
EOF
  else
    cat <<'EOF'
/etc/firefox/policies
/usr/lib/firefox/distribution
/usr/lib64/firefox/distribution
/usr/lib/firefox-esr/distribution
/usr/lib64/firefox-esr/distribution
/opt/firefox/distribution
EOF
  fi
}

install_firefox_policy() {
  [[ "$ENABLE_FIREFOX_POLICY" -eq 1 ]] || return 0

  local policy_json='{
  "policies": {
    "ImportEnterpriseRoots": true
  }
}'
  local installed=0

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if sudo mkdir -p "$dir" 2>/dev/null; then
      echo "$policy_json" | sudo tee "$dir/policies.json" >/dev/null
      log "Wrote Firefox policy: $dir/policies.json"
      installed=1
    fi
  done < <(firefox_policy_dirs)

  (( installed )) || warn "Could not place Firefox policy file in any known directory."
}

# ── Firefox NSS profile import ─────────────────────────────────────────────────

find_firefox_profiles() {
  local bases=(
    "$HOME/.mozilla/firefox"
    "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
    "$HOME/snap/firefox/common/.mozilla/firefox"
    "$HOME/Library/Application Support/Firefox/Profiles"
  )

  local found=()
  local base profile
  for base in "${bases[@]}"; do
    [[ -d "$base" ]] || continue
    for profile in "$base"/*.default* "$base"/*.esr "$base"/*.profile*; do
      [[ -d "$profile" ]] && found+=("$profile")
    done
  done

  printf '%s\n' "${found[@]}" | awk '!seen[$0]++'
}

init_nss_db_if_needed() {
  local profile="$1"
  if [[ ! -f "$profile/cert9.db" || ! -f "$profile/key4.db" ]]; then
    certutil -N -d "sql:$profile" --empty-password >/dev/null 2>&1 || true
  fi
}

nickname_for_cert() {
  local cert="$1"
  local nick
  nick="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null \
          | sed 's/^subject=//')"
  [[ -n "$nick" ]] || nick="$(basename "$cert" .crt)"
  echo "$nick"
}

import_into_firefox_profiles() {
  [[ "$IMPORT_FIREFOX" -eq 1 ]] || return 0

  # If the enterprise-roots policy is active, Firefox will automatically pull
  # certs from the system trust store — no need to run certutil per-profile.
  if [[ "$ENABLE_FIREFOX_POLICY" -eq 1 ]]; then
    log "Skipping NSS profile import: ImportEnterpriseRoots policy handles this automatically."
    return 0
  fi

  need_cmd certutil || {
    warn "certutil not found; skipping Firefox NSS import."
    return 0
  }

  mapfile -t PROFILES < <(find_firefox_profiles)

  if (( ${#PROFILES[@]} == 0 )); then
    warn "No Firefox profiles found; skipping NSS import."
    return 0
  fi

  local profile cert nick total imported skipped
  total="$(find named -maxdepth 1 -type f -name 'dod_*.crt' | wc -l | tr -d ' ')"

  for profile in "${PROFILES[@]}"; do
    log "Importing into Firefox profile: $profile (0/$total)..."
    init_nss_db_if_needed "$profile"

    imported=0; skipped=0
    for cert in named/*.crt; do
      nick="$(nickname_for_cert "$cert")"
      if certutil -L -d "sql:$profile" -n "$nick" >/dev/null 2>&1; then
        (( skipped += 1 ))
      else
        certutil -A -d "sql:$profile" -n "$nick" -t "C,," -i "$cert" >/dev/null 2>&1 \
          || warn "Failed to import $(basename "$cert") into $profile"
        (( imported += 1 ))
      fi
      (( (imported + skipped) % 10 == 0 )) \
        && log "  ...$(( imported + skipped ))/$total certs processed"
    done

    log "Profile done: $imported imported, $skipped already present."
  done
}

# ── Main ───────────────────────────────────────────────────────────────────────

install_system_certs
install_firefox_policy
import_into_firefox_profiles

if [[ "$OS_FAMILY" == "macos" ]]; then
  log "Done. DoD certificates added to macOS System Keychain."
else
  SYSTEM_COUNT="$(find "$ANCHORS_DIR" -maxdepth 1 -type f -name 'dod_*.crt' | wc -l | tr -d ' ')"
  log "Done. Installed $SYSTEM_COUNT DoD cert file(s) into system trust."
fi
[[ "$IMPORT_FIREFOX" -eq 1 ]] && log "Firefox profile import attempted for discovered profiles."

if [[ "$OS_FAMILY" == "macos" ]]; then
  cat <<'EOF'

Verification:
  System Keychain:
    security find-certificate -a -c "DoD" /Library/Keychains/System.keychain | grep "labl"
  Firefox profiles:
    certutil -L -d sql:"$HOME/Library/Application Support/Firefox/Profiles/<profile>" | grep -i dod

EOF
else
  cat <<EOF

Verification:
  Arch / RHEL (p11-kit):
    trust list | grep -i dod | head
  Debian/Ubuntu/SUSE/Gentoo:
    ls /etc/ssl/certs | grep -i dod | head
  Firefox profiles:
    certutil -L -d sql:\$HOME/.mozilla/firefox/<profile> | grep -i dod

EOF
fi
