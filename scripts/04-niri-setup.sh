#!/bin/bash

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

check_root

log ">>> Starting Phase 4: Niri Environment & Dotfiles Setup"

# ------------------------------------------------------------------------------
# 0. Identify Target User (Automated)
# ------------------------------------------------------------------------------
log "Step 0/9: Identify User"

DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)

if [ -n "$DETECTED_USER" ]; then
    TARGET_USER="$DETECTED_USER"
    log "-> Automatically detected target user: $TARGET_USER"
else
    warn "Could not detect a standard user (UID 1000)."
    while true; do
        read -p "Please enter the target username: " TARGET_USER
        if id "$TARGET_USER" &>/dev/null; then
            break
        else
            warn "User '$TARGET_USER' does not exist."
        fi
    done
fi

HOME_DIR="/home/$TARGET_USER"
log "-> Installing configurations for: $TARGET_USER ($HOME_DIR)"

# ------------------------------------------------------------------------------
# [SAFETY CHECK] Detect Existing Display Managers
# ------------------------------------------------------------------------------
log "[SAFETY CHECK] Checking for active Display Managers..."

DMS=("gdm" "sddm" "lightdm" "lxdm" "ly")
SKIP_AUTOLOGIN=false

for dm in "${DMS[@]}"; do
    if systemctl is-enabled "$dm.service" &>/dev/null; then
        log "-> Detected active Display Manager: $dm"
        log "-> Niri will be available in the $dm session list."
        log "-> TTY auto-login configuration will be SKIPPED to avoid conflicts."
        SKIP_AUTOLOGIN=true
        break
    fi
done

if [ "$SKIP_AUTOLOGIN" = false ]; then
    log "-> No active Display Manager detected. Will configure TTY auto-login."
fi

# ------------------------------------------------------------------------------
# 1. Install Niri & Essentials
# ------------------------------------------------------------------------------
log "Step 1/9: Installing Niri and core components..."
pacman -S --noconfirm --needed niri xwayland-satellite xdg-desktop-portal-gnome fuzzel kitty firefox libnotify mako polkit-gnome > /dev/null 2>&1
success "Niri core packages installed."

# ------------------------------------------------------------------------------
# 2. File Manager (Nautilus) Setup
# ------------------------------------------------------------------------------
log "Step 2/9: Configuring Nautilus and Terminal..."

pacman -S --noconfirm --needed ffmpegthumbnailer gvfs-smb nautilus-open-any-terminal file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav nautilus > /dev/null 2>&1

# Symlink Kitty to Gnome-Terminal (Safe Mode)
if [ -f /usr/bin/gnome-terminal ] && [ ! -L /usr/bin/gnome-terminal ]; then
    warn "/usr/bin/gnome-terminal is a real file (Standard Gnome Terminal installed)."
    warn "Skipping symlink creation to prevent breaking existing installation."
else
    log "-> Symlinking kitty to gnome-terminal..."
    ln -sf /usr/bin/kitty /usr/bin/gnome-terminal
fi

# Patch Nautilus
DESKTOP_FILE="/usr/share/applications/org.gnome.Nautilus.desktop"
if [ -f "$DESKTOP_FILE" ]; then
    log "-> Patching Nautilus .desktop file..."
    sed -i 's/^Exec=/Exec=env GSK_RENDERER=gl GTK_IM_MODULE=fcitx /' "$DESKTOP_FILE"
fi

# ------------------------------------------------------------------------------
# 3. Software Store
# ------------------------------------------------------------------------------
log "Step 3/9: Configuring Software Center..."
pacman -S --noconfirm --needed flatpak gnome-software > /dev/null 2>&1
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub > /dev/null 2>&1
success "Flatpak configured."

# ------------------------------------------------------------------------------
# 4. Install Dependencies from List (Robust Mode)
# ------------------------------------------------------------------------------
log "Step 4/9: Installing dependencies from niri-applist.txt..."

LIST_FILE="$PARENT_DIR/niri-applist.txt"

if [ -f "$LIST_FILE" ]; then
    # 读取文件到数组，并过滤注释和空行
    mapfile -t PACKAGE_ARRAY < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE")
    
    if [ ${#PACKAGE_ARRAY[@]} -gt 0 ]; then
        # --- 预处理：构建安装列表并自动纠错 ---
        CLEAN_LIST=""
        for pkg in "${PACKAGE_ARRAY[@]}"; do
            # 自动修复常见的 imagemagic 拼写错误
            if [ "$pkg" == "imagemagic" ]; then
                log "-> [Auto-Fix] Correcting typo 'imagemagic' to 'imagemagick'..."
                pkg="imagemagick"
            fi
            CLEAN_LIST+="$pkg "
        done
        
        log "-> Attempting batch installation of ${#PACKAGE_ARRAY[@]} packages..."
        
        # --- 尝试 1: 批量安装 (效率最高) ---
        # --answerdiff=None --answerclean=None 防止 yay 在编译时因为等待用户输入 y/n 而卡住
        if runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None $CLEAN_LIST; then
            success "All dependencies installed successfully (Batch mode)."
        else
            error "Batch installation failed (likely due to an invalid package name)."
            warn "Switching to 'One-by-One' mode to ensure valid packages get installed..."
            
            # --- 尝试 2: 逐个安装兜底 (容错率高) ---
            for pkg in $CLEAN_LIST; do
                log "-> Installing: $pkg"
                if runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$pkg"; then
                    # 安装成功，不输出额外信息，保持清爽
                    : 
                else
                    error "Failed to install '$pkg'. Skipping."
                fi
            done
            success "Dependency installation process finished (with some errors)."
        fi
    else
        warn "niri-applist.txt is empty."
    fi
else
    warn "niri-applist.txt not found at $LIST_FILE. Skipping."
fi
# ------------------------------------------------------------------------------
# 5. Clone Dotfiles (With Backup)
# ------------------------------------------------------------------------------
log "Step 5/9: Cloning and applying dotfiles..."

REPO_URL="https://github.com/SHORiN-KiWATA/ShorinArchExperience-ArchlinuxGuide.git"
TEMP_DIR="/tmp/shorin-repo"
rm -rf "$TEMP_DIR"

log "-> Cloning repository..."
runuser -u "$TARGET_USER" -- git clone "$REPO_URL" "$TEMP_DIR"

if [ -d "$TEMP_DIR/dotfiles" ]; then
    # BACKUP LOGIC
    BACKUP_NAME="config_backup_$(date +%s).tar.gz"
    log "-> [BACKUP] Backing up existing ~/.config to ~/$BACKUP_NAME..."
    runuser -u "$TARGET_USER" -- tar -czf "$HOME_DIR/$BACKUP_NAME" -C "$HOME_DIR" .config
    
    log "-> Applying new dotfiles..."
    cp -rf "$TEMP_DIR/dotfiles/." "$HOME_DIR/"
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR"
    success "Dotfiles applied. Backup saved at ~/$BACKUP_NAME"
else
    error "Directory 'dotfiles' not found."
fi

# ------------------------------------------------------------------------------
# 6. Wallpapers
# ------------------------------------------------------------------------------
log "Step 6/9: Setting up Wallpapers..."
WALL_DEST="$HOME_DIR/Pictures/Wallpapers"
if [ -d "$TEMP_DIR/wallpapers" ]; then
    mkdir -p "$WALL_DEST"
    cp -rf "$TEMP_DIR/wallpapers/." "$WALL_DEST/"
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/Pictures"
fi
rm -rf "$TEMP_DIR"

# ------------------------------------------------------------------------------
# 7. DDCUtil
# ------------------------------------------------------------------------------
log "Step 7/9: Configuring ddcutil..."
runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed ddcutil-service > /dev/null 2>&1
gpasswd -a "$TARGET_USER" i2c

# ------------------------------------------------------------------------------
# 8. SwayOSD
# ------------------------------------------------------------------------------
log "Step 8/9: Installing SwayOSD..."
pacman -S --noconfirm --needed swayosd > /dev/null 2>&1
systemctl enable --now swayosd-libinput-backend.service > /dev/null 2>&1

# ------------------------------------------------------------------------------
# 9. Auto-Login & Niri Autostart
# ------------------------------------------------------------------------------
log "Step 9/9: Configuring Auto-login..."

if [ "$SKIP_AUTOLOGIN" = true ]; then
    echo -e "${YELLOW}[INFO] Existing Display Manager detected. Skipping TTY auto-login setup.${NC}"
    echo -e "${YELLOW}[INFO] Please select 'Niri' from your login screen session menu.${NC}"
else
    # 9.1 Getty Auto-login (配置 TTY1 免密登录)
    GETTY_DIR="/etc/systemd/system/getty@tty1.service.d"
    mkdir -p "$GETTY_DIR"
    cat <<EOT > "$GETTY_DIR/autologin.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noreset --noclear --autologin $TARGET_USER - \${TERM}
EOT

    # 9.2 Niri User Service (创建 Systemd 用户服务文件)
    USER_SYSTEMD_DIR="$HOME_DIR/.config/systemd/user"
    mkdir -p "$USER_SYSTEMD_DIR"
    
    cat <<EOT > "$USER_SYSTEMD_DIR/niri-autostart.service"
[Unit]
Description=Niri Session Autostart
After=graphical-session-pre.target

[Service]
ExecStart=/usr/bin/niri-session
Restart=on-failure

[Install]
WantedBy=default.target
EOT

    # 9.3 Manually Enable the Service (手动模拟 systemctl enable)
    # 这一步代替了原来的 runuser systemctl 命令，解决了 DBus 连接失败的问题
    log "-> Enabling niri-autostart.service (Manual Symlink)..."
    
    WANTS_DIR="$USER_SYSTEMD_DIR/default.target.wants"
    mkdir -p "$WANTS_DIR"
    
    # 创建软链接：从 wants 目录指回上一级的 .service 文件
    ln -sf "../niri-autostart.service" "$WANTS_DIR/niri-autostart.service"

    # 9.4 Fix Permissions (至关重要：把所有权还给用户)
    log "-> Fixing permissions for .config..."
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config"
    
    success "TTY Auto-login configured."
fi

log ">>> Phase 4 completed. REBOOT RECOMMENDED."