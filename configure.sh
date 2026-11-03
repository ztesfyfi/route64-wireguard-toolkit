#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

INPUT=""
OUTPUT="config/config.env"
while (($#)); do
  case "$1" in
    -o|--output) [[ $# -ge 2 ]] || { echo "Missing output path" >&2; exit 2; }; OUTPUT="$2"; shift 2 ;;
    -h|--help) echo "Usage: bash configure.sh ROUTE64-WIREGUARD.conf [-o config/config.env]"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) [[ -z "$INPUT" ]] || { echo "Only one input config is supported" >&2; exit 2; }; INPUT="$1"; shift ;;
  esac
done

[[ -n "$INPUT" && -r "$INPUT" ]] || { echo "Provide a readable Route64-generated WireGuard .conf file." >&2; exit 1; }
[[ ! -e "$OUTPUT" ]] || { echo "Refusing to overwrite $OUTPUT; choose another path or move the existing file first." >&2; exit 1; }

ini_get() {
  local section="$1" key="$2"
  awk -F= -v wanted_section="[$section]" -v wanted_key="$key" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^\[/ { current=trim($0); next }
    current == wanted_section {
      name=trim($1)
      if (name == wanted_key) {
        $1=""
        sub(/^[[:space:]]*=/, "")
        value=trim($0)
        sub(/[[:space:]]*[#;].*$/, "", value)
        print trim(value)
        exit
      }
    }
  ' "$INPUT"
}

raw_address="$(ini_get Interface Address)"
private_key="$(ini_get Interface PrivateKey)"
mtu="$(ini_get Interface MTU)"
peer_public_key="$(ini_get Peer PublicKey)"
endpoint="$(ini_get Peer Endpoint)"
allowed_ips="$(ini_get Peer AllowedIPs)"

# Select the first IPv6 interface address from a possibly comma-separated Address field.
route64_address=""
IFS=',' read -ra address_items <<< "$raw_address"
for item in "${address_items[@]}"; do
  item="${item//[[:space:]]/}"
  if [[ "$item" == *:*/* ]]; then route64_address="$item"; break; fi
done

[[ -n "$route64_address" ]] || { echo "Could not find an IPv6 CIDR in [Interface] Address." >&2; exit 1; }
[[ -n "$peer_public_key" ]] || { echo "Missing [Peer] PublicKey in the supplied config." >&2; exit 1; }
[[ -n "$endpoint" ]] || { echo "Missing [Peer] Endpoint in the supplied config." >&2; exit 1; }
[[ "$route64_address$private_key$peer_public_key$endpoint$allowed_ips$mtu" != *'"'* ]] || { echo "Unexpected quote character in input config; refusing to write shell config." >&2; exit 1; }

echo "Imported current tunnel values from: $INPUT"
echo "Tunnel address: $route64_address"
echo "Route64 endpoint: $endpoint"
echo "Peer public key: present"
read -r -p "Enter the routed prefix shown for THIS tunnel in the Route64 manager (for example, its assigned /56): " routed_prefix
[[ -n "$routed_prefix" ]] || { echo "Routed prefix is required; no value guessed." >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT")"
{
  printf '# Generated from the current Route64 manager config. Review before installation.\n'
  printf 'ROUTE64_PRIVATE_KEY="%s"\n' "$private_key"
  printf 'ROUTE64_PUBLIC_KEY="%s"\n' "$peer_public_key"
  printf 'ROUTE64_ENDPOINT="%s"\n' "$endpoint"
  printf 'ROUTE64_ADDRESS="%s"\n' "$route64_address"
  printf 'ROUTE64_ALLOWED_IPS="%s"\n' "${allowed_ips:-::/1,8000::/1}"
  printf 'ROUTE64_MTU="%s"\n' "${mtu:-1420}"
  printf 'ROUTED_PREFIX="%s"\n' "$routed_prefix"
  printf 'ENABLE_DOWNSTREAM_WG1="no"\n'
  printf 'WG1_PRIVATE_KEY=""\n'
  printf 'WG1_LISTEN_PORT="51821"\n'
  printf 'WG1_SERVER_ADDRESS=""\n'
  printf 'WG1_CLIENT_PUBLIC_KEY=""\n'
  printf 'WG1_CLIENT_ADDRESS=""\n'
} > "$OUTPUT"
chmod 600 "$OUTPUT"

echo "Wrote $OUTPUT with mode 600."
echo "Review it before running install.sh. The imported private key is sensitive."
echo "If the imported PrivateKey is blank, generate/register a key with Route64 before expecting the tunnel to handshake."
