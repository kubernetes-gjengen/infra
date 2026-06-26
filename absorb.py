#!/usr/bin/env -S uv run --script
#
# /// script
# requires-python = ">=3.12"
# dependencies = ["scapy"]
# ///
import socket
import scapy.all
import subprocess
import time

s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"enp2s0") #remember to change interface on other devices
while True:
    frame, addr = s.recvfrom(2048)
    packet = scapy.all.Ether(frame)    
    
    if not packet.src.startswith(("28:cd:c1", "b8:27:eb", "d8:3a:dd", "dc:a6:32", "e4:5f:01")):
        continue
    if not packet.haslayer(scapy.all.DHCP):
        continue
    options = packet["DHCP"].options
    for option, value in options:
        if option == "requested_addr":
            ip = value
            break
    else:
        continue
    time.sleep(1) # Give it a second

    print(f"PI detected at MAC:{packet.src}, IP:{ip} . Provisioning...")

    try:
        subprocess.run(["ansible-playbook", "playbooks/provision-single.yml", "-e", f"new_host_ip={ip}"], check=True)
    except subprocess.CalledProcessError as e:
        print("Provision failed:")
        print(e.stdout)
        print(e.stderr)
        
    print("Provisioning complete")
