# Batman Manet

This repository can help you to build a MANET with the _batman_ protocol.

## General Idea

The idea is to first install the cluster via _ansible_. This includes installing _batman_ on the pis and configuring it. We also want to install a service which starts batman after a reboot, to ensure that we can test node-failure.

Once the network is running, we want to have access to it via a controller (our laptop). To achieve this, we connect to one of the pis with an ethernet cable and bridge the network.

## Setup

### Ansible

Make sure to install ansible on your machine. Next connect all pis to the same network (via ethernet) and make sure they can be reached. Collect their IP addresses and write them down in an inventory file `pis.ini`. You can now install via the `config-batman.yml` playbook with the command:

```
ansible-playbook -i pis.ini config-batman.yml
```

### Batman

You can test whether all nodes joined the network by running

```
sudo batctl n
```

This is the [wiki](https://www.open-mesh.org/projects/batman-adv/wiki/Using-batctl)

### Batman service

The batman service is currently NOT installed by the ansible playbook (feel free to improve this). To make it work, copy over the service to `/etc/systemd/system/` and enable it with `sudo systemctl enable batman`
The service relies on a file called `ip_addr` which contains the desired ip address for the device. IF THIS FILE DOESNT EXIST THE SERVICE WILL FAIL. Right now, its not created by the ansible playbook and has to be created manually (feel free to improve this)

### Bridge

Time to access the network. Connect one of the pis via ethernet to the same network as you laptop (can also be without router). Then, execute the `bridge.sh` script. It will assign hard-coded ips. Get your local network config right and you will be able to connect to the network.

### Next steps

Test the network. Make sure you can reach all pis from the your laptop and that the pis can reach the internet. Next, you can install a Kubernetes cluster.
