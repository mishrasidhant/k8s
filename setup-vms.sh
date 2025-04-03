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
HOST_ONLY_CIDR="192.168.60.0/24"
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
PRESEED_DIR="${PWD}/preseed"
CLOUDINIT_DIR="${PWD}/cloudinit"
FLOPPY_IMAGE="${PRESEED_DIR}/preseed.img"
# Check for dependencies
check_dependencies() {
    local dependencies=("VBoxManage" "curl" "wget" "sha256sum" "mkfs.msdos" "mcopy" "genisoimage" "bsdtar" "sed")
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            exit_on_error "Dependency '$dep' is not installed. Please install it and re-run the script."
        fi
    done
    log_message "All required dependencies are installed."
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

# Generate preseed dependencies (file and ISO)
generate_preseed() {
    mkdir -p "$PRESEED_DIR"
    cat <<EOF > "$PRESEED_DIR/preseed.cfg"
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
# To enable auto-reboot, replace the next line with:
# d-i debian-installer/exit/reboot boolean true
EOF
    log_message "Preseed file generated successfully in $PRESEED_DIR."

    create_preseed_iso
}

# Create ISO image from preseed file
create_preseed_iso(){
    genisoimage -output "${PRESEED_DIR}/preseed.iso" -volid cidata -joliet -rock "$PRESEED_DIR/preseed.cfg" \
    || exit_on_error "Failed to create preseed ISO."
    log_message "Preseed ISO created."
}

# Create floppy disk image for the preseed file
# create_floppy_disk() {
#     log_message "Creating floppy disk image for preseed."
#     # mkfs.msdos -C "$FLOPPY_IMAGE" 1440 || exit_on_error "Failed to create floppy disk image."
#     mkfs.ext2 -F "$FLOPPY_IMAGE" 1440 || exit_on_error "Failed to create floppy disk image."
#     mcopy -i "$FLOPPY_IMAGE" "$PRESEED_DIR/preseed.cfg" :: || exit_on_error "Failed to copy preseed file to floppy disk."
#     log_message "Floppy disk image created successfully."
# }

# Generate and package cloud-init files into ISO
generate_cloud_init() {
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
        cat <<EOF > "$CLOUDINIT_DIR/$VM_NAME-cloud-init.yaml"
#cloud-config
hostname: ${VM_NAME}.k8s.local
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

        # Package the YAML file into an ISO
        genisoimage -output "${CLOUDINIT_DIR}/${VM_NAME}-cloud-init.iso" -volid cidata -joliet -rock "${CLOUDINIT_DIR}/$VM_NAME-cloud-init.yaml" \
            || exit_on_error "Failed to create cloud-init ISO for VM $VM_NAME."
        log_message "Cloud-init ISO created for VM $VM_NAME."
    done
}

# Validate and create host-only network
create_host_only_network() {
    log_message "Creating host-only network with CIDR $HOST_ONLY_CIDR."
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

        # Attach preseed ISO as a virtual CD-ROM to the SATA Controller
        VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 2 --device 0 --type dvddrive --medium "${PRESEED_DIR}/preseed.iso" \
            || exit_on_error "Failed to attach preseed ISO to VM $VM_NAME."

        # Attach the cloud-init ISO as a virtual CD-ROM to the SATA Controller
        VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 3 --device 0 --type dvddrive --medium "${CLOUDINIT_DIR}/${VM_NAME}-cloud-init.iso" \
            || exit_on_error "Failed to attach cloud-init ISO to VM $VM_NAME."

        # # Attach preseed and cloud-init files
        # attach_files_to_vm "$VM_NAME"

        # Add kernel boot parameters for the preseed file
        log_message "Adding kernel boot parameters for preseed to VM $VM_NAME."
        VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/pcbios/0/Config/DmiBIOSVersion" "auto=true DEBIAN_FRONTEND=text preseed/file=/cdrom/preseed.cfg" \
            || exit_on_error "Failed to add boot parameters to VM $VM_NAME."

        # Set the boot order to prioritize the Debian ISO
        VBoxManage modifyvm "$VM_NAME" --boot1 dvd --boot2 dvd --boot3 disk || exit_on_error "Failed to set boot order for VM $VM_NAME."
    done
}

# Attach preseed and cloud-init files to a VM
# attach_files_to_vm() {
    # VM_NAME="$1"

    # Add a Floppy Controller to the VM
    # log_message "Adding Floppy Controller to VM $VM_NAME."
    # VBoxManage storagectl "$VM_NAME" --name "Floppy Controller" --add floppy \
    #     || exit_on_error "Failed to add Floppy Controller to VM $VM_NAME."

    # Attach the preseed floppy disk to the Floppy Controller
    # log_message "Attaching preseed floppy disk to VM $VM_NAME."
    # VBoxManage storageattach "$VM_NAME" --storagectl "Floppy Controller" --port 0 --device 0 --type fdd --medium "$FLOPPY_IMAGE" \
    #     || exit_on_error "Failed to attach preseed floppy disk to VM $VM_NAME."

    # Attach preseed ISO as a virtual CD-ROM to the SATA Controller
    # VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 2 --device 0 --type dvddrive --medium "${PRESEED_DIR}/preseed.iso" \
    # || exit_on_error "Failed to attach preseed ISO to VM $VM_NAME."


    # Attach the cloud-init ISO as a virtual CD-ROM to the SATA Controller
    # VBoxManage storageattach "$VM_NAME" --storagectl "SATA Controller" --port 3 --device 0 --type dvddrive --medium "${CLOUDINIT_DIR}/${VM_NAME}-cloud-init.iso" \
    #     || exit_on_error "Failed to attach cloud-init ISO to VM $VM_NAME."

    # Add kernel boot parameters for the preseed file
#     log_message "Adding kernel boot parameters for preseed to VM $VM_NAME."
#     VBoxManage setextradata "$VM_NAME" "VBoxInternal/Devices/pcbios/0/Config/DmiBIOSVersion" "auto priority=critical preseed/file=/cdrom/preseed.cfg" \
#         || exit_on_error "Failed to add boot parameters to VM $VM_NAME."

#     log_message "Attached preseed and cloud-init ISO to VM $VM_NAME with updated boot parameters."
# }

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

    # Check for prerequisites
    check_dependencies

    # Validate the chosen IP range
    validate_ip_range
    # TODO Add this function back in ^

    # Download and validate the ISO
    validate_and_download_iso

    # Generate and package preseed file
    generate_preseed

    # # Create the floppy disk image
    # create_floppy_disk

    # Generate and package cloud-init files into ISO
    generate_cloud_init

    # Create the host-only network
    create_host_only_network

    # Create the virtual machines
    create_vms

    # Output a summary of all the created VMs
    output_summary

    log_message "Script completed successfully."
}

# Run the script
main