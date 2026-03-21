#!/usr/bin/env bash
# =============================================================================
# Arch Linux Automated Installation Script
# Target: KDE Plasma | SDDM | ext4 | UEFI
# Partitions: /boot (EFI) | / (root, 50GB) | /home (remainder)
#
# USAGE:
#   1. Boot from the Arch Linux live ISO.
#   2. Ensure you have an internet connection (use iwctl for Wi-Fi).
#   3. Edit the CONFIGURATION section below to match your system.
#   4. Run: bash arch_install.sh
#
# WARNING: This script will ERASE the target disk entirely. Double-check
#          the DISK variable before running!
# =============================================================================

set -euo pipefail   # Exit on error, unset variable, or pipe failure
trap 'echo "[ERROR] Script failed at line $LINENO." >&2' ERR

# =============================================================================
# CONFIGURATION — Edit these values before running
# =============================================================================

DISK="/dev/sda"           # Target disk (e.g. /dev/sda, /dev/nvme0n1)
BOOT_SIZE="512MiB"        # EFI partition size
ROOT_SIZE="50GiB"         # Root partition size (remainder goes to /home)

HOSTNAME="archlinux"      # System hostname
LOCALE="en_US.UTF-8"      # System locale
KEYMAP="us"               # Console keymap

# CPU microcode: "intel-ucode" or "amd-ucode" — pick one for your CPU
MICROCODE="intel-ucode"

# Extra packages to install alongside the base system
EXTRA_PACKAGES="vim git curl wget btop"

# =============================================================================
# HELPERS
# =============================================================================

info()    { echo -e "\n\e[1;34m[INFO]\e[0m  $*"; }
success() { echo -e "\e[1;32m[OK]\e[0m    $*"; }
warn()    { echo -e "\e[1;33m[WARN]\e[0m  $*"; }

# Resolve partition names correctly for NVMe vs standard block devices
# e.g. /dev/sda -> /dev/sda1 | /dev/nvme0n1 -> /dev/nvme0n1p1
part() {
    if [[ "$DISK" == *"nvme"* ]]; then
        echo "${DISK}p${1}"
    else
        echo "${DISK}${1}"
    fi
}

# =============================================================================
# INTERACTIVE PROMPTS — Collect user-specific configuration at runtime
# =============================================================================

# Helper: prompt for a value with a default fallback
prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="$3"
    read -rp "$prompt_text [default: $default]: " input
    # Use the entered value, or fall back to the default if left blank
    printf -v "$var_name" '%s' "${input:-$default}"
}

# Helper: prompt for a password (hidden input), with confirmation loop
prompt_password() {
    local var_name="$1"
    local prompt_text="$2"
    local pass confirm
    while true; do
        read -rsp "$prompt_text: " pass; echo
        read -rsp "Confirm password: " confirm; echo
        if [[ "$pass" == "$confirm" ]]; then
            printf -v "$var_name" '%s' "$pass"
            break
        else
            echo "[ERROR] Passwords do not match. Please try again."
        fi
    done
}

echo "========================================================"
echo "      Arch Linux Installer — Interactive Setup"
echo "========================================================"
echo ""

# --- Username ---
prompt USERNAME "Enter standard user username" "user"

# --- User password (hidden, confirmed) ---
prompt_password USER_PASSWORD "Enter password for '$USERNAME'"

# --- Root password (hidden, confirmed) ---
prompt_password ROOT_PASSWORD "Enter root password"

# --- Timezone ---
echo ""
echo "Tip: Run 'timedatectl list-timezones' to see all valid timezone strings."
prompt TIMEZONE "Enter timezone" "America/Chicago"

# Validate the timezone against the zoneinfo database
if [[ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    echo "[ERROR] Invalid timezone '$TIMEZONE'. Please re-run the script with a valid value." >&2
    exit 1
fi

echo ""
echo "Configuration summary:"
echo "  Username  : $USERNAME"
echo "  Timezone  : $TIMEZONE"
echo "  Passwords : (set, not shown)"
echo ""
read -rp "Proceed with installation? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# =============================================================================
# STEP 1 — Verify UEFI boot mode
# =============================================================================
info "Verifying UEFI boot mode..."
if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo "[ERROR] System is not booted in UEFI mode. Exiting." >&2
    exit 1
fi
success "UEFI mode confirmed."

# =============================================================================
# STEP 2 — Sync system clock via NTP
# =============================================================================
info "Synchronising system clock..."
timedatectl set-ntp true
success "Clock synchronised."

# =============================================================================
# STEP 3 — Partition the disk
# Layout:
#   Part 1 — EFI  (FAT32,  $BOOT_SIZE)
#   Part 2 — root (ext4,   $ROOT_SIZE)
#   Part 3 — home (ext4,   remainder)
# =============================================================================
info "Partitioning disk: $DISK"
warn "ALL DATA ON $DISK WILL BE DESTROYED."

# Wipe existing partition table and create a fresh GPT
sgdisk --zap-all "$DISK"
sgdisk --clear "$DISK"

# Create the three partitions
sgdisk --new=1:0:+"$BOOT_SIZE"  --typecode=1:ef00 --change-name=1:"EFI"  "$DISK"
sgdisk --new=2:0:+"$ROOT_SIZE"  --typecode=2:8300 --change-name=2:"ROOT" "$DISK"
sgdisk --new=3:0:0              --typecode=3:8300 --change-name=3:"HOME" "$DISK"

# Inform the kernel of partition table changes
partprobe "$DISK"
success "Disk partitioned."

# =============================================================================
# STEP 4 — Format the partitions
# =============================================================================
info "Formatting partitions..."

# EFI partition must be FAT32
mkfs.fat -F32 -n EFI "$(part 1)"

# Root and home use ext4
mkfs.ext4 -L ROOT "$(part 2)"
mkfs.ext4 -L HOME "$(part 3)"

success "Partitions formatted."

# =============================================================================
# STEP 5 — Mount the filesystems
# =============================================================================
info "Mounting filesystems..."

mount "$(part 2)" /mnt                   # Mount root first

mkdir -p /mnt/boot /mnt/home
mount "$(part 1)" /mnt/boot              # Mount EFI partition
mount "$(part 3)" /mnt/home              # Mount home partition

success "Filesystems mounted."

# =============================================================================
# STEP 6 — Install base system packages
# =============================================================================
info "Installing base system (this may take a while)..."

pacstrap -K /mnt \
    base \
    base-devel \
    linux \
    linux-firmware \
    "$MICROCODE" \
    networkmanager \
    $EXTRA_PACKAGES

success "Base system installed."

# =============================================================================
# STEP 7 — Generate fstab
# =============================================================================
info "Generating /etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
success "fstab generated."

# =============================================================================
# STEP 8 — Chroot and configure the system
# Everything below runs inside the new installation via arch-chroot.
# =============================================================================
info "Entering chroot to configure the system..."

arch-chroot /mnt /bin/bash <<CHROOT_COMMANDS
set -euo pipefail

# --- Timezone ---
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc   # Sync hardware clock to UTC

# --- Locale ---
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# --- Hostname & hosts ---
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# --- Root password ---
echo "root:${ROOT_PASSWORD}" | chpasswd

# --- Install KDE Plasma, SDDM, and related packages ---
pacman -S --noconfirm \
    plasma-meta \
    kde-applications-meta \
    sddm \
    xorg \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    wireplumber \
    cups \
    print-manager

# --- Enable essential services ---
systemctl enable NetworkManager    # Networking
systemctl enable sddm              # Display manager (login screen)
systemctl enable cups              # Printing service

# --- Install and configure GRUB bootloader ---
pacman -S --noconfirm grub efibootmgr
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot \
    --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# --- Create non-root user and add to wheel group ---
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# --- Grant wheel group sudo access (passworded) ---
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

CHROOT_COMMANDS

success "Chroot configuration complete."

# =============================================================================
# STEP 9 — Unmount and finish
# =============================================================================
info "Unmounting filesystems..."
umount -R /mnt
success "Done! You can now reboot into your new Arch Linux + KDE Plasma system."
echo ""
echo "  Credentials:"
echo "    Root password : $ROOT_PASSWORD"
echo "    User          : $USERNAME / $USER_PASSWORD"
echo ""
echo "  Remember to change your passwords after first login!"
