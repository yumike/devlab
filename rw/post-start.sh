#!/usr/bin/env bash
set -euo pipefail

if [[ "${RW_DEVCONTAINER_FIREWALL:-1}" != "1" ]]; then
  echo "[rw devcontainer] firewall: OFF (RW_DEVCONTAINER_FIREWALL=$RW_DEVCONTAINER_FIREWALL)"
  exit 0
fi

echo "[rw devcontainer] firewall: ENABLING (set RW_DEVCONTAINER_FIREWALL=0 on host to disable)"
sudo /usr/local/bin/init-firewall.sh
