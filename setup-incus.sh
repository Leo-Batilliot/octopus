#!/usr/bin/env bash
set -euo pipefail

HOSTS=(redis-1 postgresql-1 poll-1 result-1 worker-1)
IMAGE="images:debian/13"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"

if [[ ! -f "$SSH_KEY" ]]; then
  echo ">> Pas de clé SSH, génération..."
  ssh-keygen -t ed25519 -N "" -f "${SSH_KEY%.pub}"
fi
PUBKEY=$(cat "$SSH_KEY")

read -r -d '' CLOUDINIT <<EOF || true
#cloud-config
users:
  - name: debian
    groups: sudo
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUBKEY
package_update: true
packages:
  - openssh-server
  - python3
EOF

echo ">> Création des conteneurs..."
for h in "${HOSTS[@]}"; do
  if incus info "$h" &>/dev/null; then
    echo "   $h existe déjà, on saute"
    continue
  fi
  incus launch "$IMAGE" "$h" -c user.user-data="$CLOUDINIT"
done

echo ">> Attente de l'init (SSH + python) ..."
sleep 20

echo ">> Génération du fichier production..."
{
  echo "[redis]"
  echo "redis-1 ansible_host=$(incus list redis-1 -c4 --format csv | awk '{print $1}')"
  echo
  echo "[postgresql]"
  echo "postgresql-1 ansible_host=$(incus list postgresql-1 -c4 --format csv | awk '{print $1}')"
  echo
  echo "[poll]"
  echo "poll-1 ansible_host=$(incus list poll-1 -c4 --format csv | awk '{print $1}')"
  echo
  echo "[result]"
  echo "result-1 ansible_host=$(incus list result-1 -c4 --format csv | awk '{print $1}')"
  echo
  echo "[worker]"
  echo "worker-1 ansible_host=$(incus list worker-1 -c4 --format csv | awk '{print $1}')"
  echo
  echo "[all:vars]"
  echo "ansible_user=debian"
  echo "ansible_ssh_private_key_file=${SSH_KEY%.pub}"
  echo "ansible_ssh_common_args='-o StrictHostKeyChecking=no'"
} > production

echo ">> Fichier 'production' généré :"
cat production
echo
echo ">> Test de connexion :"
ansible -i production all -m ping
