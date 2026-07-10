#!/bin/bash
#Why use many commands when few tokens do trick?

# `batctl ra` only sets the algorithm for a bat0 that doesn't exist yet - if
# one is already lingering (leftover from a previous run/boot this session),
# it's a no-op and bat0 silently keeps whatever algorithm it already had
# (observed defaulting to BATMAN_IV), splitting the mesh between nodes that
# happened to have a clean slate and nodes that didn't.
sudo ip link set bat0 down 2>/dev/null
sudo ip link delete bat0 2>/dev/null

sudo batctl ra BATMAN_V
sudo ip link set wlan0 down
sudo iwconfig wlan0 mode ad-hoc
sudo iwconfig wlan0 essid "meshnet"
sudo iwconfig wlan0 channel 1 # or 6 or 11
sudo ip link set wlan0 up
sudo batctl if add wlan0
sudo ip link set bat0 mtu 1476 # Make room for batman encapsulation 