#!/bin/bash
set -e

NITRO_VERSION="v1.4.4"
INSTALL_DIR="/tmp/nitro-enclaves-install"

echo "==== AWS Nitro Enclaves Installation Script for Ubuntu 24.04 ===="
echo "Version: $NITRO_VERSION"
echo ""

echo "Step 1: Installing system dependencies..."
sudo apt update
sudo apt install -y \
    docker.io \
    build-essential \
    cmake \
    libssl-dev \
    git \
    gcc \
    make \
    llvm-dev \
    libclang-dev \
    clang \
    linux-headers-$(uname -r)

echo ""
echo "Step 2: Setting up Docker..."
sudo systemctl start docker
sudo systemctl enable docker

# Add current user to docker group if not already
if ! groups $USER | grep -q docker; then
    sudo usermod -aG docker $USER
    echo "Added $USER to docker group"
    DOCKER_GROUP_ADDED=true
else
    DOCKER_GROUP_ADDED=false
fi

# If we just added the user to docker group, use sg to run docker commands
if [ "$DOCKER_GROUP_ADDED" = true ]; then
    echo ""
    echo "NOTE: Docker group was just added. Docker commands in this script will use 'sg docker' to apply group membership."
    echo "      After installation completes, you MUST log out and log back in for permanent group access."
    DOCKER_PREFIX="sg docker -c"
else
    DOCKER_PREFIX=""
fi

echo ""
echo "Step 3: Downloading and building Nitro Enclaves CLI..."
cd /tmp
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
fi

git clone --depth 1 --branch $NITRO_VERSION https://github.com/aws/aws-nitro-enclaves-cli.git "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Building nitro-cli (this may take a few minutes)..."
if [ "$DOCKER_GROUP_ADDED" = true ]; then
    sg docker -c "make nitro-cli"
else
    make nitro-cli
fi

echo "Building vsock-proxy..."
if [ "$DOCKER_GROUP_ADDED" = true ]; then
    sg docker -c "make vsock-proxy"
else
    make vsock-proxy
fi

echo "Running make install..."
sudo make install

echo ""
echo "Step 4: Installing binaries and configurations to system paths..."
sudo cp -r ./build/install/usr/bin/* /usr/bin/
sudo cp -r ./build/install/usr/lib/systemd/system/* /usr/lib/systemd/system/
sudo cp -r ./build/install/etc/nitro_enclaves /etc/
sudo cp -r ./build/install/usr/share/nitro_enclaves /usr/share/

echo ""
echo "Step 5: Installing kernel module..."
sudo mkdir -p /lib/modules/$(uname -r)/extra/nitro_enclaves/
sudo cp ./build/install/lib/modules/$(uname -r)/extra/nitro_enclaves/nitro_enclaves.ko \
    /lib/modules/$(uname -r)/extra/nitro_enclaves/
sudo depmod -a

# NOTE: We do NOT auto-load the module at boot to avoid race conditions
# The allocator service will load it when needed

echo ""
echo "Step 6: Creating runtime directories..."
sudo mkdir -p /var/log/nitro_enclaves
sudo mkdir -p /run/nitro_enclaves

# Create tmpfiles.d configuration for runtime directories
sudo mkdir -p /etc/tmpfiles.d
sudo tee /etc/tmpfiles.d/nitro-enclaves.conf << 'EOF'
d /run/nitro_enclaves 0775 root ne - -
d /var/log/nitro_enclaves 0775 root ne - -
EOF

echo ""
echo "Step 7: Creating ne group and setting up permissions..."
if ! getent group ne > /dev/null 2>&1; then
    sudo groupadd -r ne
    echo "Created 'ne' group"
fi

# Add current user to ne group
if ! groups $USER | grep -q ne; then
    sudo usermod -aG ne $USER
    echo "Added $USER to 'ne' group"
fi

# Set permissions on runtime directories for ne group
sudo chown root:ne /var/log/nitro_enclaves
sudo chmod 775 /var/log/nitro_enclaves
sudo chown root:ne /run/nitro_enclaves
sudo chmod 775 /run/nitro_enclaves

# Apply tmpfiles configuration
sudo systemd-tmpfiles --create /etc/tmpfiles.d/nitro-enclaves.conf

# Set up udev rule for device permissions
sudo tee /etc/udev/rules.d/99-nitro-enclaves.rules << 'EOF'
KERNEL=="nitro_enclaves", GROUP="ne", MODE="0660"
EOF

echo ""
echo "Step 8: Configuring allocator service..."
# Update allocator service to load module before allocating resources
sudo tee /usr/lib/systemd/system/nitro-enclaves-allocator.service << 'EOF'
[Unit]
Description=Nitro Enclaves Resource Allocator
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe nitro_enclaves
ExecStart=/usr/bin/nitro-enclaves-allocator
ExecStop=/usr/bin/nitro-enclaves-allocator --deallocate

[Install]
WantedBy=multi-user.target
EOF

echo ""
echo "Step 9: Configuring allocator..."
# Pin enclave to CPUs 46-47 (NUMA node 1, freed from EuroLLM in docker-compose.yml)
# This avoids conflicts with vLLM CPU bindings:
#   Apertus:  0-11, 48-59
#   OlMo:    12-23, 60-71
#   EuroLLM: 24-45, 72-93
#   Enclave: 46-47 (+ hyperthreads 94-95 taken automatically)
echo "Configuring allocator: 2 CPUs (pool: 46-47), 2048 MiB"
cat << 'EOF' | sudo tee /etc/nitro_enclaves/allocator.yaml
---
cpu_count: 2
cpu_pool: "46-47"
memory_mib: 2048
EOF

echo ""
echo "Step 10: Starting Nitro Enclaves allocator service..."
sudo systemctl daemon-reload
sudo systemctl enable nitro-enclaves-allocator.service
sudo systemctl start nitro-enclaves-allocator.service

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger

echo ""
echo "Step 11: Verifying installation..."
echo ""

# Check device
if [ -e /dev/nitro_enclaves ]; then
    echo "✓ /dev/nitro_enclaves device exists"
    ls -l /dev/nitro_enclaves
else
    echo "✗ /dev/nitro_enclaves device NOT found"
fi

echo ""

# Check kernel module
if lsmod | grep -q nitro_enclaves; then
    echo "✓ Kernel module loaded"
    lsmod | grep nitro_enclaves
else
    echo "✗ Kernel module NOT loaded"
fi

echo ""

# Check allocator service
if systemctl is-active --quiet nitro-enclaves-allocator.service; then
    echo "✓ Allocator service running"
    sudo systemctl status nitro-enclaves-allocator.service --no-pager -l
else
    echo "✗ Allocator service NOT running"
    sudo systemctl status nitro-enclaves-allocator.service --no-pager -l
fi

echo ""

# Check nitro-cli
if command -v nitro-cli &> /dev/null; then
    echo "✓ nitro-cli installed"
    nitro-cli --version
else
    echo "✗ nitro-cli NOT found in PATH"
fi

echo ""

# Check runtime directories
if [ -d /run/nitro_enclaves ]; then
    echo "✓ Runtime directory exists"
    ls -ld /run/nitro_enclaves
else
    echo "✗ Runtime directory missing"
fi

echo ""

# Try to describe enclaves (using sg if needed for group)
echo "Testing nitro-cli..."
if [ "$DOCKER_GROUP_ADDED" = true ]; then
    # Need to also check ne group with sg
    if sg ne -c "nitro-cli describe-enclaves" &> /dev/null; then
        echo "✓ nitro-cli working (with sg - logout/login needed for permanent group access)"
        sg ne -c "nitro-cli describe-enclaves"
    elif sudo nitro-cli describe-enclaves &> /dev/null; then
        echo "✓ nitro-cli working (with sudo)"
        sudo nitro-cli describe-enclaves
    else
        echo "✗ nitro-cli test failed"
        sudo nitro-cli describe-enclaves
    fi
else
    if nitro-cli describe-enclaves &> /dev/null; then
        echo "✓ nitro-cli working (without sudo)"
        nitro-cli describe-enclaves
    elif sudo nitro-cli describe-enclaves &> /dev/null; then
        echo "✓ nitro-cli working (with sudo - logout/login needed for group to take effect)"
        sudo nitro-cli describe-enclaves
    else
        echo "✗ nitro-cli test failed"
        sudo nitro-cli describe-enclaves
    fi
fi

echo ""
echo "Allocated resources:"
echo "  CPUs: $(cat /sys/module/nitro_enclaves/parameters/ne_cpus 2>/dev/null || echo 'N/A')"
MEMORY_BYTES=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo '0')
MEMORY_MIB=$((MEMORY_BYTES * 1024))
echo "  Memory: ${MEMORY_MIB} MiB"

echo ""
echo "Step 12: Setting up daily cron job for Lucid location agent..."
# Install the run script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sudo cp "$SCRIPT_DIR/run-lucid-enclave.sh" /opt/lucid-agent/run-lucid-enclave.sh 2>/dev/null || {
    sudo mkdir -p /opt/lucid-agent
    sudo cp "$SCRIPT_DIR/run-lucid-enclave.sh" /opt/lucid-agent/run-lucid-enclave.sh
}
sudo chmod +x /opt/lucid-agent/run-lucid-enclave.sh

# Add cron job: daily at 04:00 UTC
CRON_ENTRY="0 4 * * * /opt/lucid-agent/run-lucid-enclave.sh >> /var/log/nitro_enclaves/cron.log 2>&1"
(sudo crontab -l 2>/dev/null | grep -v "run-lucid-enclave"; echo "$CRON_ENTRY") | sudo crontab -
echo "Cron job installed: daily at 04:00 UTC"

echo ""
echo "==== Installation Complete ===="
echo ""
if [ "$DOCKER_GROUP_ADDED" = true ]; then
    echo "IMPORTANT: You were added to the 'docker' and 'ne' groups during installation."
    echo "You MUST log out and log back in for these group changes to take permanent effect."
    echo ""
fi
echo "To verify allocated resources:"
echo "  cat /sys/module/nitro_enclaves/parameters/ne_cpus"
echo "  cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"
echo ""
echo "To modify allocator settings:"
echo "  sudo nano /etc/nitro_enclaves/allocator.yaml"
echo "  sudo systemctl restart nitro-enclaves-allocator.service"
echo ""
echo "Example: Build and run AWS's hello world enclave:"
echo "  nitro-cli build-enclave --docker-uri public.ecr.aws/aws-nitro-enclaves/hello:latest --output-file hello.eif"
echo "  nitro-cli run-enclave --cpu-count 2 --memory 2048 --eif-path hello.eif --debug-mode"
echo "  nitro-cli console --enclave-id <ENCLAVE_ID>"
echo ""
echo "Cleanup: Remove build directory with:"
echo "  rm -rf $INSTALL_DIR"
echo "  REBOOT INSTANCE for configuration to take effect"
