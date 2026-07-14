#!/bin/bash
#Why use many commands when few tokens do trick?

# `batctl ra` only sets algorithm for a bat0 that doesn't exist yet - a
# lingering one silently keeps its old algorithm (seen: BATMAN_IV default),
# splitting the mesh between clean-slate and dirty nodes.
sudo ip link set wlan0 down
sudo iwconfig wlan0 mode ad-hoc
sudo iwconfig wlan0 essid "meshnet"
sudo iwconfig wlan0 channel 1 # or 6 or 11
sudo ip link set wlan0 up
sudo batctl if add wlan0
sudo batctl ra BATMAN_V
# Cursed bootstrap: `batctl ra` needs bat0 to exist, but bat0 must be
# recreated after `ra` for the algorithm to stick. So: delete, re-add.
sudo ip link set bat0 down 2>/dev/null
sudo ip link delete bat0 2>/dev/null
sudo ip link set wlan0 nomaster
sudo batctl if add wlan0
sudo ip link set bat0 mtu 1476 # Make room for batman encapsulation 
