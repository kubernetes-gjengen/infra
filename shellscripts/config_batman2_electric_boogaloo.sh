#!/bin/bash
#Why use many commands when few tokens do trick?

# Overridable via systemd Environment= (see batman.service, templated from
# mesh_ssid/mesh_channel in group_vars/all.yml) - defaults match this
# project's mesh config when run standalone.
MESH_SSID="${MESH_SSID:-meshnet}"
MESH_CHANNEL="${MESH_CHANNEL:-1}"

sudo ip link set wlan0 down
sudo iwconfig wlan0 mode ad-hoc
sudo iwconfig wlan0 essid "$MESH_SSID"
sudo iwconfig wlan0 channel "$MESH_CHANNEL" # or 6 or 11
sudo ip link set wlan0 up
sudo batctl if add wlan0
sudo ip link set bat0 mtu 1476 # Make room for batman encapsulation
