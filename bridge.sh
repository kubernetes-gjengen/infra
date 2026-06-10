#!/bin/bash

BAT_IP=$(ip -4 addr show bat0 | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+')

ip link add dev br0 type bridge
ip link set dev eth0 master br0
ip link set dev bat0 master br0
ip link set dev br0 up
ip addr flush dev eth0
ip addr flush dev bat0
ip addr add $BAT_IP dev br0
ip link set eth0 up
