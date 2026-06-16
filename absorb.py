import socket
import scapy.all
import ansible_runner
import time

import signal

print("SIGINT handler:", signal.getsignal(signal.SIGINT))
signal.signal(signal.SIGINT, signal.SIG_DFL)

s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"enp2s0")
# s.bind(("enp2s0",0))
while True:
    frame, addr = s.recvfrom(2048)
    packet = scapy.all.Ether(frame)
    # print(packet.src)

    if packet.src.startswith(
        ("28:cd:c1", "b8:27:eb", "d8:3a:dd", "dc:a6:32", "e4:5f:01")
    ):
        if packet.haslayer(scapy.all.DHCP):
            options = packet["DHCP"].options
            for option, value in options:
                if option == "requested_addr":
                    ip = value
                    break
            else:
                continue
            time.sleep(1)  # Give it a second

            # Add RPI to inventory
            # Run playbook with RPI IP as arg
            args = {"new_host_ip": ip}
            print(f"PI detected at {packet.src}. Provisioning...")
            print("SIGINT handler:", signal.getsignal(signal.SIGINT))
            thread, res = ansible_runner.run_async(
                private_data_dir=".",
                playbook="playbooks/provision-single.yml",
                extravars=args,
            )
            thread.join()
            print("Provisioning complete")
            print(res.status)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            print("SIGINT handler:", signal.getsignal(signal.SIGINT))

            # RPI detected
