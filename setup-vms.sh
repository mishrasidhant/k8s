#!/bin/bash

# Log messages with timestamps
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Exit on error
exit_on_error() {
    log_message "ERROR: $1"
    exit 1
}

# Default configurations
GATEWAY_IP="192.168.60.1"
VM_BASE_DIR="/vms"
ISO_DIR="${PWD}"
ISO_NAME="debian-12.10.0-amd64-netinst.iso"
ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.10.0-amd64-netinst.iso"
CHECKSUM_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS"
USERNAME="username"
PASSWORD="password"
MEMORY_WORKERS="2048"
CPUS_WORKERS="1"
DISK_SIZE_WORKERS="10000"
MEMORY_CONTROLLER="2048"
CPUS_CONTROLLER="2"
DISK_SIZE_CONTROLLER="10000"
MEMORY_NFS="2048"
CPUS_NFS="1"
DISK_SIZE_NFS="20000"
VM_NAMES=("controller" "worker1" "worker2" "nfs")
PREFIX=""
LOG_FILE="vm_setup.log"

# Check for dependencies
check_dependencies() {
    local dependencies=("VBoxManage" "curl" "wget" "sha256sum")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            exit_on_error "Dependency '$dep' is not installed. Please install it and re-run the script."
        fi
    done
}

# Validate and download Debian ISO
validate_and_download_iso() {
    CHECKSUM_FILE="SHA256SUMS"

    # Check for ISO file
    if [ ! -f "$ISO_NAME" ]; then
        log_message "ISO file not found. Downloading ISO from $ISO_URL."
        wget -q "$ISO_URL" -O "$ISO_NAME" || exit_on_error "Failed to download Debian ISO."
    fi

    # Check for checksum file
    if [ ! -f "$CHECKSUM_FILE" ]; then
        log_message "Checksum file not found. Downloading checksum file from $CHECKSUM_URL."
        wget -q "$CHECKSUM_URL" -O "$CHECKSUM_FILE" || exit_on_error "Failed to download checksum file."
    fi

    # Validate checksum
    log_message "Validating checksum for $ISO_NAME."
    grep "$ISO_NAME" "$CHECKSUM_FILE" | sha256sum --check > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_message "Checksum validation failed for $ISO_NAME."
        log_message "Expected checksum: $(grep "$ISO_NAME" "$CHECKSUM_FILE" | awk '{print $1}')"
        log_message "Actual checksum: $(sha256sum "$ISO_NAME" | awk '{print $1}')"
        exit_on_error "Checksum validation failed. Please investigate the issue."
    else
        log_message "Checksum validated successfully."
    fi
}

# Generate preseed file
generate_preseed_file() {
    cat <<EOF > preseed.cfg
d-i debian-installer/locale string en_US.UTF-8
d-i debian-installer/keymap select us
d-i time/zone string UTC
d-i partman-auto/disk string /dev/sda
d-i partman-auto/method string regular
d-i partman-auto/expert_recipe string boot-root :: \
      100 500 10000 ext4 \
      $primary{ } $bootable{ } \
      method{ format } format{ } \
      use_filesystem{ } filesystem{ ext4 } \
      mountpoint{ / } \
      .
d-i partman/choose_partition select finish
d-i partman/confirm write_partition yes
d-i passwd/user-fullname string $USERNAME
d-i passwd/username string $USERNAME
d-i passwd/user-password password $PASSWORD
d-i passwd/user-password-again password $PASSWORD
d-i passwd/user-default-groups string sudo
d-i grub-installer/bootdev string default
d-i pkgsel/include string openssh-server
d-i pkgsel/install-language-support boolean false
d-i finish-install/reboot_in_progress note
d-i debian-installer/exit/reboot boolean true
EOF
    log_message "Preseed file generated successfully."
}

# Generate cloud-init files
generate_cloud_init_files() {
    for VM in "${VM_NAMES[@]}"; do
        VM_NAME="$VM"
        [ -n "$PREFIX" ] && VM_NAME="${PREFIX}-${VM}"
        case "$VM" in
            controller)
                IP="192.168.60.100"
                PACKAGES="curl nfs-common"
                ;;
            worker1)
                IP="192.168.60.101"
                PACKAGES="curl nfs-common"
                ;;
            worker2)
                IP="192.168.60.102"
                PACKAGES="curl nfs-common"
                ;;
            nfs)
                IP="192.168.60.103"
                PACKAGES="curl nfs-kernel-server"
                ;;
        esac
        cat <<EOF > "$VM_NAME-cloud-init.yaml"
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - ${IP}/24
      gateway4: ${GATEWAY_IP}
      nameservers:
        addresses:
          - 8.8.8.8
packages:
  - ${PACKAGES}
EOF
        log_message "Cloud-init file generated for $VM_NAME."
    done
}

# Validate and create host-only network
create_host_only_network() {
    log_message "Creating host-only network with $GATEWAY_IP/24."
    VBoxManage hostonlyif create || exit_on_error "Failed to create host-only network."
    NETWORK_NAME=$(VBoxManage list hostonlyifs | grep "^Name:" | awk '{print $2}' | tail -n 1)

    if [ -z "$NETWORK_NAME" ]; then
        exit_on_error "Failed to retrieve the name of the host-only network."
    fi

    log_message "Configuring network $NETWORK_NAME with gateway IP $GATEWAY_IP."
    VBoxManage hostonlyif ipconfig "$NETWORK_NAME" --ip "$GATEWAY_IP" --netmask "255.255.255.0" \
        || exit_on_error "Failed to configure IP and netmask for $NETWORK_NAME."
    log_message "Host-only network '$NETWORK_NAME' created successfully."
}

# Create and configure VMs
create_vms() {
    for VM in "${VM_NAMES[@]}"; do
        VM_NAME="$VM"
        [ -n "$PREFIX" ] && VM_NAME="${PREFIX}-${VM}"

        VM_DIR="${VM_BASE_DIR}/${VM_NAME}"
        mkdir -p "$VM_DIR"

        case "$VM" in
            controller)
                MEMORY="$MEMORY_CONTROLLER"
                CPUS="$CPUS_CONTROLLER"
                DISK_SIZE="$DISK_SIZE_CONTROLLER"
                ;;
            worker1 | worker2)
                MEMORY="$MEMORY_WORKERS"
                CPUS="$CPUS_WORKERS"
                DISK_SIZE="$DISK_SIZE_WORKERS"
                ;;
            nfs)
                MEMORY="$MEMORY_NFS"
                CPUS="$CPUS_NFS"
                DISK_SIZE="$DISK_SIZE_NFS"
                ;;
        esac

        log_message "Creating VM: $VM_NAME with $MEMORY MB RAM, $CPUS CPUs, $DISK_SIZE MB disk."
        VBoxManage createvm --name "$VM_NAME" --ostype Debian_64 --basefolder "$VM_BASE_DIR" --register \
            || exit_on_error "Failed to create VM $VM_NAME."
        VBoxManage modifyvm "$VM_NAME" --memory "$MEMORY" --cpus "$CPUS" --nic1 nat --nic2 hostonly --hostonlyadapter2 "$NETWORK_NAME" \
            || exit_on_error "Failed to configure VM $VM_NAME."
        VBoxManage storagectl "$VM_NAME" --name "SATA Controller" --add sata --controller IntelAhci \
            || exit_on_error "Failed to add storage controller for VM $VM_NAME."
        VBoxManage createmedium disk --filename "${VM_DIR}/${VM_NAME}.vdi" --size "$DISK_SIZE" \
            || exit_on_error "Failed to create disk for VM $VM_NAME."
        VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "${VM_DIR}/${VM_NAME}.vdi" \
            || exit_on_error "Failed to attach disk for VM $VM_NAME."
        VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 1 --device 0 --type dvddrive --medium "$ISO_DIR/$ISO_NAME" \
            || exit_on_error "Failed to attach ISO for VM $VM_NAME."
        VBoxManage modifyvm "$VM_NAME" --boot1 dvd --boot2 disk || exit_on_error "Failed to set boot order for VM $VM_NAME."
    done
}

# Output a summary of created VMs
output_summary() {
    echo "Summary of Created VMs:" >> "$LOG_FILE"
    for VM in "${VM_NAMES[@]}"; do
        VM_NAME="$VM"
        [ -n "$PREFIX" ] && VM_NAME="${PREFIX}-${VM}"
        echo "- $VM_NAME: Memory=${MEMORY}, CPUs=${CPUS}, Disk=${DISK_SIZE}MB" >> "$LOG_FILE"
    done
    log_message "VM creation completed successfully. Check the log file for details: $LOG_FILE."
}

# Main script execution
main() {
    log_message "Starting VirtualBox VM setup script."

    check_dependencies
    validate_and_download_iso
    generate_preseed_file
    generate_cloud_init_files
    create_host_only_network
    create_vms
    output_summary

    log_message "Script completed successfully."
}

# Run the script
main