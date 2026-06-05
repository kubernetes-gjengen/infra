#!/bin/bash
ip link add dev br0 type bridge
ip link set dev eth0 master br0
ip link set dev bat0 master br0
ip link set dev br0 up
ip addr flush dev eth0
ip addr flush dev bat0
ip addr add 192.168.3.15/24 dev br0
ip addr add 192.168.3.100/24 dev br0
ip link set eth0 up
