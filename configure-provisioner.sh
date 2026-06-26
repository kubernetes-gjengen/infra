#!/bin/bash
#needs sudo
set -euo pipefail

mkdir -p /opt/edge-cluster
mkdir -p /opt/edge-cluster/playbooks

cp absorb.py /opt/edge-cluster/dhcp-listener.py
cp playbooks/provision-single.yml /opt/edge-cluster/playbooks
cp pis.ini /opt/edge-cluster
cp config_batman.sh /opt/edge-cluster
cp ansible.cfg /opt/edge-cluster

cp auto-provision.service /etc/systemd/system

if id "edgecluster" &>/dev/null; then
    echo "Skipping user creating since it already exists"
else
    sudo useradd \
        --system \
        --home /opt/edge-cluster \
        --shell /usr/sbin/nologin \
        edgecluster
fi

chown -R edgecluster:edgecluster /opt/edge-cluster

systemctl daemon-reload
systemctl restart auto-provision.service
echo Success