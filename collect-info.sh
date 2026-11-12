#!/usr/bin/env bash

# shellcheck disable=SC1091,SC2016  # os-release is sourced on purpose; backticks are markdown
set -uo pipefail

SERVICES=(nginx docker fail2ban firewalld apparmor ssh avahi-daemon cron)

if [[ $EUID -ne 0 ]]; then
    echo "Please log in as root and run this script."
    exit 1
fi

have()    { command -v "$1" >/dev/null 2>&1; }
h2()      { printf '\n## %s\n\n' "$1"; }
trim()    { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
dmi()     { cat "/sys/class/dmi/id/$1" 2>/dev/null; }

# /dev/sda1 -> /dev/sda (a whole-disk filesystem maps to itself)
parent_disk() {
  local dev="${1%%\[*}" p
  p=$(lsblk -dno PKNAME "$dev" 2>/dev/null | head -1)
  printf '/dev/%s' "${p:-${dev#/dev/}}"
}
disk_field() { lsblk -dno "$1" "$2" 2>/dev/null | head -1 | trim; }

# --- Overview -----------------------------------------------------------------

os_pretty=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
os_version=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-unknown}")
kernel=$(uname -r)
host=$(hostname)
ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
  | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')

h2 "Overview"
printf '| Property | Value |\n| --- | --- |\n'
printf '| **Hostname** | `%s` |\n' "$host"
printf '| **OS** | %s |\n' "$os_pretty"
printf '| **Kernel** | Linux %s |\n' "$kernel"
printf '| **Local IP** | `%s` |\n' "${ip:-n/a}"
printf '| **Domain** | `%s.local` |\n' "$host"

# --- Hardware -----------------------------------------------------------------

cpu=$(lscpu 2>/dev/null | awk -F: '/^Model name/ { print $2; exit }' | trim \
  | sed 's/([A-Za-z]*)//g; s/ CPU//; s/  */ /g; s/\([0-9]\)GHz/\1 GHz/')
cores=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/ { c = $2 + 0 } /^Socket\(s\)/ { s = $2 + 0 } END { print c * s }')
threads=$(nproc --all 2>/dev/null)
ram_gib=$(awk '/^MemTotal/ { v = $2 / 1048576; printf "%d", (v == int(v)) ? v : int(v) + 1 }' /proc/meminfo)
swap_kb=$(awk '/^SwapTotal/ { print $2 }' /proc/meminfo)

root_src=$(findmnt -no SOURCE / 2>/dev/null)
os_disk=$(parent_disk "$root_src")
os_mounts=$(lsblk -lno MOUNTPOINT "$os_disk" 2>/dev/null | grep -E '^(/|/boot/efi)$' | sort -u \
  | sed 's/.*/`&`/' | paste -sd'|' | sed 's/|/ + /g')

h2 "Hardware"
printf '| Component | Details |\n| --- | --- |\n'
printf '| **Model** | %s |\n' "$(dmi product_name | trim)"
printf '| **CPU** | %s (%sC/%sT) |\n' "$cpu" "$cores" "$threads"
printf '| **RAM** | %s GiB |\n' "$ram_gib"
if [[ ${swap_kb:-0} -eq 0 ]]; then
  printf '| **Swap** | None |\n'
else
  printf '| **Swap** | %s GiB |\n' "$(awk -v k="$swap_kb" 'BEGIN { printf "%.1f", k / 1048576 }')"
fi
printf '| **OS disk** | %s %s (`%s`) — %s |\n' \
  "$(disk_field MODEL "$os_disk")" "$(disk_field SIZE "$os_disk")" "$os_disk" "${os_mounts:-n/a}"

h2 "Storage disks"
printf '| Disk | Size | Partition Table | Mountpoint | Device | Used |\n'
printf '| --- | --- | --- | --- | --- | --- |\n'
findmnt -rno TARGET,SOURCE 2>/dev/null | awk '$1 ~ /^\/srv\// && $2 ~ /^\/dev\//' | sort \
  | while read -r target source; do
      disk=$(parent_disk "$source")
      printf '| %s | %s | %s | `%s` | `%s` | %s |\n' \
        "$(disk_field MODEL "$disk")" "$(disk_field SIZE "$disk")" \
        "$(disk_field PTTYPE "$disk" | tr '[:lower:]' '[:upper:]')" \
        "$target" "$source" "$(df -h --output=pcent "$target" | tail -1 | trim)"
    done

# --- Versions -----------------------------------------------------------------

nginx_v=$(nginx -v 2>&1 | sed -n 's|.*nginx/||p')
docker_v=$(docker version -f '{{.Server.Version}}' 2>/dev/null)
[[ -n $docker_v ]] || docker_v=$(docker --version 2>/dev/null | sed -n 's/^Docker version \([^,]*\),.*/\1/p')

h2 "Versions (badges)"
printf -- '- Debian: %s\n' "$os_version"
printf -- '- Kernel: %s (full: %s)\n' "${kernel%%[+-]*}" "$kernel"
printf -- '- Hardware: %s\n' "$(dmi product_name | trim)"
printf -- '- Nginx: %s\n' "${nginx_v:-n/a}"
printf -- '- Docker: %s\n' "${docker_v:-n/a}"

h2 "Docker containers"
if have docker && docker ps >/dev/null 2>&1; then
  printf '| Stack | Service | Image | Ports |\n| --- | --- | --- | --- |\n'
  docker ps --format '{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}\t{{.Image}}\t{{.Ports}}' \
    | sort \
    | awk -F'\t' '{
        p = $4
        if (p == "") p = "internal"
        else if (p !~ /->/) { sub(/\/tcp/, "", p); p = "internal (" p ")" }
        else p = "`" p "`"
        printf "| %s | `%s` | `%s` | %s |\n", $1, $2, $3, p
      }'
else
  echo "docker not available (or no permission)"
fi

# --- Services & security ------------------------------------------------------

h2 "Services"
printf '| Service | Status |\n| --- | --- |\n'
for svc in "${SERVICES[@]}"; do
  state=$(systemctl is-active "$svc" 2>/dev/null)
  printf '| **%s** | %s |\n' "$svc" "${state:-n/a}"
done

h2 "Security"
if have firewall-cmd; then
  printf -- '- Firewalld default zone: %s\n' "$(firewall-cmd --get-default-zone 2>/dev/null)"
  while read -r zone; do
    printf -- '- Zone `%s`: %s\n' "$zone" "$(firewall-cmd --zone="$zone" --list-services 2>/dev/null)"
  done < <(firewall-cmd --get-active-zones 2>/dev/null | awk '/^[^[:space:]]/ { print $1 }')
fi
if have fail2ban-client; then
  printf -- '- Fail2ban jails: %s\n' \
    "$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
fi
if have aa-status; then
  printf -- '- AppArmor: %s\n' "$(aa-status 2>/dev/null | grep -m1 'profiles are loaded' | trim)"
fi

h2 "Open ports (non-loopback)"
printf '| Port | Protocol | Process |\n| --- | --- | --- |\n'
ss -H -tulnp 2>/dev/null | awk '
  $5 ~ /^127\./ || $5 ~ /^\[::1\]/ { next }
  {
    n = split($5, a, ":")
    proc = ""
    if (match($NF, /\(\("[^"]+"/)) proc = substr($NF, RSTART + 3, RLENGTH - 4)
    key = a[n] " " $1
    if (!(key in seen)) { seen[key] = 1; print a[n], toupper($1), proc }
  }' | sort -n -k1,1 -k2,2 | awk '{ printf "| %s | %s | %s |\n", $1, $2, $3 }'
