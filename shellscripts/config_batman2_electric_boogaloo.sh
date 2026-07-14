#!/bin/bash
#Why use many commands when few tokens do trick?

sudo ip link set wlan0 down
sudo iwconfig wlan0 mode ad-hoc
sudo iwconfig wlan0 essid "meshnet"
sudo iwconfig wlan0 channel 1 # or 6 or 11
sudo ip link set wlan0 up
sudo batctl if add wlan0
sudo ip link set bat0 mtu 1476 # Make room for batman encapsulation
