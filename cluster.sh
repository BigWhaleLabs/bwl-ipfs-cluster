#!/bin/bash

set -x

USER=ec2-user
GROUP=ec2-user

# Update these when appropriate
IPFS_VERSION=v0.4.21
IPFS_CLUSTER_VERSION=v0.10.1

# If you're setting up a peer for an existing cluster, uncomment this line and fill in its multiaddr
# BOOTSTRAP=/dns4/example.com/tcp/9096/ipfs/Qmfoo...

# Replace this with the cluster secret from your root peer if you're bootstrapping
CLUSTER_SECRET=$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')
echo "export CLUSTER_SECRET=${CLUSTER_SECRET}" >>/home/${USER}/.bash_profile

# comment this line out if you want to use local storage
# or replace it with your EBS volume mount point
VOLUME=/dev/sdb

# Enter the size of the volume, or the max repo size of your local storage
IPFS_REPO_SIZE=32GB

# install-dist takes two or three arguments:
# $1 is the project name to fetch from dist.ipfs.io/$1
# $2 is the version string to install
# $3 is the name of the resulting executable, defaulting to the project name
install-dist() {
    lib=$1
    version=$2
    [ -z "$3" ] && bin=${lib} || bin=$3
    archive=${lib}_${version}_linux-amd64.tar.gz
    wget -P /tmp https://dist.ipfs.io/${lib}/${version}/${archive}
    tar xvfz /tmp/${archive} -C /tmp
    mv /tmp/${lib}/${bin} /usr/local/bin
    rm -rf /tmp/${archive} /tmp/${lib}
}

install-dist go-ipfs ${IPFS_VERSION} ipfs
install-dist ipfs-cluster-service ${IPFS_CLUSTER_VERSION}
install-dist ipfs-cluster-ctl ${IPFS_CLUSTER_VERSION}

# initialize disk if $VOLUME is set
if [ -z "${VOLUME}" ]; then
    mkdir /data
else
    # the EBS volume mount points is really a symlink
    # to /dev/nvme1n1 or something
    disk=$(readlink -f ${VOLUME})

    # Check if there is already a filesystem
    fs=$(file -s ${disk})
    if [ "${fs}" = "${disk}: data" ]; then
        # If there is no filesystem, make a new one
        mkfs -t ext4 ${disk}
    fi

    # Mount the disk to /data
    mkdir /data
    mount ${disk} /data

    # Find the uuid of the disk and edit /etc/fstab to mount it automatically
    uuid=$(blkid -s UUID -o value ${disk})
    line="UUID=${uuid} /data ext4 defaults,nofail 0 2"
    echo ${line} >>/etc/fstab
fi

# Set IPFS_PATH and IPFS_CLUSTER_PATH env variables
export IPFS_PATH=/data/ipfs
export IPFS_CLUSTER_PATH=/data/ipfs-cluster
echo "export IPFS_PATH=${IPFS_PATH}" >>/home/${USER}/.bash_profile
echo "export IPFS_CLUSTER_PATH=${IPFS_CLUSTER_PATH}" >>/home/${USER}/.bash_profile

# Initialize IPFS repo
mkdir -p ${IPFS_PATH} ${IPFS_CLUSTER_PATH}

if [ ! -f /data/ipfs/config ]; then
    ipfs init --profile server --empty-repo
    ipfs config Datastore.StorageMax ${IPFS_REPO_SIZE}
    ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/8080
    ipfs config Addresses.API /ip4/0.0.0.0/tcp/5001
    ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin '["https://underlay.github.io"]'
    ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods '["GET"]'
fi

# Initialize IPFS Cluster
if [ ! -f /data/ipfs-cluster/service.json ]; then
    ipfs-cluster-service init
fi

# The config files written during init are currently owned by root
chown -R ${USER}:${GROUP} ${IPFS_PATH} ${IPFS_CLUSTER_PATH}

# Install the ipfs systemctl service
cat >/lib/systemd/system/ipfs.service <<EOF
[Unit]
Description=IPFS daemon
After=network.target
[Service]
ExecStart=/usr/local/bin/ipfs daemon
Restart=on-failure
User=${USER}
Group=${GROUP}
Environment="IPFS_PATH=/data/ipfs"
[Install]
WantedBy=multi-user.target
EOF

if [ -z "${BOOTSTRAP}" ]; then
    CLUSTER_BOOTSTRAP=""
    CLUSTER_LEAVEONSHUTDOWN=false
else
    CLUSTER_BOOTSTRAP="--bootstrap ${BOOTSTRAP}"
    CLUSTER_LEAVEONSHUTDOWN=true
fi

# Install the ipfs-cluster systemctl service
cat >/lib/systemd/system/ipfs-cluster.service <<EOF
[Unit]
Description=IPFS Cluster daemon
Requires=ipfs.service
After=ipfs.service
[Service]
ExecStart=/usr/local/bin/ipfs-cluster-service daemon --upgrade ${CLUSTER_BOOTSTRAP}
Restart=always
User=${USER}
Group=${GROUP}
Environment="IPFS_CLUSTER_PATH=/data/ipfs-cluster"
Environment="CLUSTER_LEAVEONSHUTDOWN=${CLUSTER_LEAVEONSHUTDOWN}"
Environment="CLUSTER_SECRET=${CLUSTER_SECRET}"
Environment="CLUSTER_RESTAPI_HTTPLISTENMULTIADDRESS=/ip4/0.0.0.0/tcp/9094"
[Install]
WantedBy=multi-user.target
EOF

# enable the new services
systemctl daemon-reload
systemctl enable ipfs.service
systemctl enable --now ipfs-cluster.service

yum install -y jq
