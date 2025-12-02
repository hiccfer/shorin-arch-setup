#!/bin/bash

# ==============================================================================
# 00-btrfs-init.sh - Pre-install Snapshot Safety Net
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

section "Phase 0" "System Snapshot Initialization"

# ------------------------------------------------------------------------------
# 1. Detect Filesystem
# ------------------------------------------------------------------------------
log "Checking filesystem type..."
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)

if [ "$ROOT_FSTYPE" != "btrfs" ]; then
    warn "Root filesystem is not Btrfs ($ROOT_FSTYPE)."
    warn "Skipping snapshot initialization."
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Install Snapper (Minimal)
# ------------------------------------------------------------------------------
log "Installing Snapper..."
# Only install snapper here, other tools (GUI/GRUB) go to 02-musthave
exe pacman -Syu --noconfirm --needed snapper

# ------------------------------------------------------------------------------
# 3. Configure Root Config
# ------------------------------------------------------------------------------
log "Configuring Snapper for / (Root)..."

if ! snapper list-configs | grep -q "^root "; then
    # Snapper requires the directory to be empty or a subvolume
    if [ -d "/.snapshots" ]; then
        log "Cleaning /.snapshots for initialization..."
        exe_silent umount /.snapshots
        exe_silent rm -rf /.snapshots
    fi
    
    if exe snapper -c root create-config /; then
        success "Config 'root' created."
        
        # Apply Retention Policy (Safe & Light)
        log "Applying retention policy..."
        exe snapper -c root set-config \
            ALLOW_GROUPS="wheel" \
            TIMELINE_CREATE="yes" \
            TIMELINE_CLEANUP="yes" \
            NUMBER_LIMIT="10" \
            NUMBER_LIMIT_IMPORTANT="5" \
            TIMELINE_LIMIT_HOURLY="5" \
            TIMELINE_LIMIT_DAILY="7" \
            TIMELINE_LIMIT_WEEKLY="0" \
            TIMELINE_LIMIT_MONTHLY="0" \
            TIMELINE_LIMIT_YEARLY="0"
    else
        error "Failed to create root config."
    fi
else
    log "Config 'root' already exists."
fi

# ------------------------------------------------------------------------------
# 4. Configure Home Config (If separate subvolume)
# ------------------------------------------------------------------------------
# Check if /home is a btrfs mount point
if findmnt -n -o FSTYPE /home | grep -q "btrfs"; then
    log "Btrfs /home detected. Configuring Snapper for /home..."
    
    if ! snapper list-configs | grep -q "^home "; then
        if [ -d "/home/.snapshots" ]; then
            exe_silent umount /home/.snapshots
            exe_silent rm -rf /home/.snapshots
        fi
        
        if exe snapper -c home create-config /home; then
            success "Config 'home' created."
            
            # Apply same retention policy
            exe snapper -c home set-config \
                ALLOW_GROUPS="wheel" \
                TIMELINE_CREATE="yes" \
                TIMELINE_CLEANUP="yes" \
                NUMBER_LIMIT="10" \
                NUMBER_LIMIT_IMPORTANT="5" \
                TIMELINE_LIMIT_HOURLY="5" \
                TIMELINE_LIMIT_DAILY="7" \
                TIMELINE_LIMIT_WEEKLY="0" \
                TIMELINE_LIMIT_MONTHLY="0" \
                TIMELINE_LIMIT_YEARLY="0"
        fi
    else
        log "Config 'home' already exists."
    fi
fi

# ------------------------------------------------------------------------------
# 5. Create Initial Safety Snapshot
# ------------------------------------------------------------------------------
section "Safety Net" "Creating Initial Snapshot"

log "Creating 'Before Install' snapshot..."
if exe snapper -c root create --description "Before Shorin Setup" --cleanup-algorithm number; then
    success "Root snapshot created."
else
    error "Failed to create root snapshot."
fi

if snapper list-configs | grep -q "^home "; then
    if exe snapper -c home create --description "Before Shorin Setup" --cleanup-algorithm number; then
        success "Home snapshot created."
    fi
fi

log "Module 00 completed. Safe to proceed."