#!/bin/bash
# Setup_Automount_CajaSegura_zswap: Multilingual automount + gocryptfs + zswap for Artix OpenRC
# TRANSLATION PRIORITY:
# 1. gettext.mo -> /usr/share/locale/LANG/LC_MESSAGES/Setup_Automount_CajaSegura_zswap.mo # For Poedit
# 2. user TXT -> ~/Translations/Setup_Automount_CajaSegura_zswap.LANG.txt # For anyone, no sudo
# 3. system XML -> /usr/share/Setup_Automount_CajaSegura_zswap/l10n/Setup_Automount_CajaSegura_zswap.LANG.xml
# 4. Embedded -> Dictionary inside this script # Fallback EN/ES
set -e
if [ "$EUID" -ne 0 ]; then exec sudo bash "$0" "$@"; fi

TEXTDOMAIN=Setup_Automount_CajaSegura_zswap # TRANSLATION: Base name for all translation files
export TEXTDOMAIN
LANG_FULL="${LANG%%.*}"
USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)

# TRANSLATION: Load user TXT from ~/Translations/Setup_Automount_CajaSegura_zswap.es.txt
declare -A USER_TXT_DICT
load_user_txt(){
  local txt_path="$USER_HOME/Translations/Setup_Automount_CajaSegura_zswap.${LANG_FULL}.txt"
  [! -f "$txt_path" ] && return
  while IFS=' read -r key val; do
    [[ "$key" =~ ^#.*$ ]] && continue # TRANSLATION: # = comment
    [ -z "$key" ] && continue
    USER_TXT_DICT["$key"]="$val"
  done < "$txt_path"
}

# TRANSLATION: Load system XML
declare -A XML_DICT
load_xml(){
  local xml_path="/usr/share/Setup_Automount_CajaSegura_zswap/l10n/Setup_Automount_CajaSegura_zswap.${LANG_FULL}.xml"
  [! -f "$xml_path" ] && return
  while IFS=' read -r key val; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [ -z "$key" ] && continue
    XML_DICT["$key"]="$val"
  done <(grep -oP '<string name="\K[^"]+" value="\K[^"]+' "$xml_path" 2>/dev/null | sed 's/" value="/=/')
}

# TRANSLATION: Main translation function tr "KEY" "arg1"
tr(){
  local key="$1"; shift
  local result=""

  if command -v gettext >/dev/null 2>&1; then
    result=$(gettext "$key" 2>/dev/null)
    [ "$result"!= "$key" ] && { printf "$result" "$@"; return; }
  fi

  [ ${#USER_TXT_DICT[@]} -eq 0 ] && load_user_txt
  [ -n "${USER_TXT_DICT[$key]}" ] && { printf "${USER_TXT_DICT[$key]}" "$@"; return; }

  [ ${#XML_DICT[@]} -eq 0 ] && load_xml
  [ -n "${XML_DICT[$key]}" ] && { printf "${XML_DICT[$key]}" "$@"; return; }

  case "${LANG_FULL%%_*}" in
    es) # TRANSLATION: Spanish
      case "$key" in
        "CajaSegura Automount Installer") result="🔒 Instalador Automontaje CajaSegura + zswap" ;;
        "Modify /etc/fstab? [y/N]: ") result="¿Modificar /etc/fstab? [s/N]: " ;;
        "Initialize gocryptfs vault? [y/N]: ") result="¿Inicializar bóveda gocryptfs? [s/N]: " ;;
        "Add CajaSegura launchers to panel? [Y/n]: ") result="¿Añadir accesos de CajaSegura al panel? [S/n]: " ;;
        "Restore %s? [y/N]: ") result="¿Restaurar %s? [s/N]: " ;;
        "Done. Reboot to apply") result="Listo. Reinicia para aplicar" ;;
        "CajaSegura Opened") result="🔓 CajaSegura Abierta" ;;
        "CajaSegura Closed") result="🔒 CajaSegura Cerrada" ;;
        "CajaSegura Password") result="Contraseña de CajaSegura" ;;
        "Open CajaSegura") result="🔓 Abrir CajaSegura" ;;
        "Close CajaSegura") result="🔒 Cerrar CajaSegura" ;;
        "Enable zswap? [Y/n]: ") result="¿Activar zswap? [S/n]: " ;;
        *) result="$key" ;;
      esac ;;
    *) result="$key" ;; # TRANSLATION: English fallback
  esac
  printf "$result" "$@"
}

ACCENT_OPEN="#00E676"; ACCENT_CLOSE="#FF3D00"; GRADIENT_START="#1A1A1A"; GRADIENT_END="#000"
USER_NAME="${SUDO_USER:-$USER}"; USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
MOUNT_BASE="/media/$USER_NAME"; CAJA_DIR=".caja_segura"; CAJA_MOUNT="CajaSegura"
BIN_DIR="$USER_HOME/.local/bin"; DESKTOP_DIR="$USER_HOME/.local/share/applications"
ICON_DIR="$USER_HOME/.local/share/icons/hicolor/scalable/apps"; SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/var/log/Setup_Automount_CajaSegura_zswap.log"; FSTAB_BACKUP="/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"
INSTALL_PANEL=false; [ "$1" = "--install-panel" ]&&INSTALL_PANEL=true

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"|tee -a "$LOG"; }
actualizar_menu(){ sudo -u "$USER_NAME" update-desktop-database "$DESKTOP_DIR" 2>/dev/null||true; }

crear_helpers(){
  export LANG_SET="${LANG_FULL%%_*}"
  declare -f tr > "$USER_HOME/.cache/Setup_Automount_CajaSegura_zswap_i18n.sh"
  chmod +x "$USER_HOME/.cache/Setup_Automount_CajaSegura_zswap_i18n.sh"

  cat > "$SCRIPT_DIR/add_xfce_launchers.sh" <<'EOF'
#!/bin/bash
source "$HOME/.cache/Setup_Automount_CajaSegura_zswap_i18n.sh" 2>/dev/null
set -e;U="${SUDO_USER:-$USER}";H=$(getent passwd "$U"|cut -d: -f6);P="$H/.config/xfce4/xfce4-panel.xml";B="$H/.config/xfce4/backups";mkdir -p "$B"
if [ "$1" = "--undo" ];then L=$(ls -t "$B"/*.bak.* 2>/dev/null|head -n1);[ -n "$L" ]&&cp "$L" "$P";xfce4-panel -r;echo "$(tr "Done. Reboot to apply")";exit 0;fi
[ -f "$P" ]||exit 1;cp "$P" "$B/xfce4-panel.xml.bak.$(date +%Y%m%d_%H%M%S)"
grep -q "cajasegura-open.desktop" "$P"||sed -i "/items.*array/a\ \ <value>cajasegura-open.desktop</value>\n \ <value>cajasegura-close.desktop</value>" "$P"
xfce4-panel -r;echo "XFCE: $(tr "Done. Reboot to apply")"
EOF

  cat > "$SCRIPT_DIR/add_i3_rofi.sh" <<'EOF'
#!/bin/bash
source "$HOME/.cache/Setup_Automount_CajaSegura_zswap_i18n.sh" 2>/dev/null
set -e;U="${SUDO_USER:-$USER}";H=$(getent passwd "$U"|cut -d: -f6);R="$H/.local/bin/rofi-cajasegura.sh"
if [ "$1" = "--undo" ];then rm -f "$R";exit 0;fi
cat > "$R" <<ROFI
#!/bin/bash
source "$HOME/.cache/Setup_Automount_CajaSegura_zswap_i18n.sh" 2>/dev/null
CHOICE=$(echo -e "$(tr "Open CajaSegura")\n$(tr "Close CajaSegura")" | rofi -dmenu -p "$(tr "CajaSegura Automount Installer")")
[ "$CHOICE" = "$(tr "Open CajaSegura")" ]&&$H/.local/bin/cajasegura-mount.sh
[ "$CHOICE" = "$(tr "Close CajaSegura")" ]&&$H/.local/bin/cajasegura-umount.sh
ROFI
chmod +x "$R";echo "i3/Sway: $(tr "Done. Reboot to apply")"
EOF
  chmod +x "$SCRIPT_DIR"/add_*_*.sh; chown "$USER_NAME:$USER_NAME" "$SCRIPT_DIR"/add_*_*.sh
}

case "$1" in
  --undo) ULTIMO=$(ls -t /etc/fstab.bak.* 2>/dev/null|head -n1);[ -n "$ULTIMO" ]&&read -p "$(tr "Restore %s? [y/N]: " "$ULTIMO")" R && [[ "$R" =~ ^[YySs] ]]&&cp "$ULTIMO" /etc/fstab;echo "$(tr "Done. Reboot to apply")";exit 0;;
  --undo-menu) echo "$(tr "Done. Reboot to apply")";exit 0;;
  --undo-all) bash "$0" --undo; bash "$0" --undo-menu;exit 0;;
esac

log "=== $(tr "CajaSegura Automount Installer") [$LANG] ==="; crear_helpers
pacman -S --noconfirm gettext udevil udisks2 gocryptfs zenity libnotify xmlstarlet desktop-file-utils rofi

read -p "$(tr "Enable zswap? [Y/n]: ")" ZSWAP; [[ "$ZSWAP" =~ ^[YySs] ]] && if! grep -q "zswap.enabled=1" /etc/default/grub 2>/dev/null; then echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT} zswap.enabled=1 zswap.compressor=zstd\"" >> /etc/default/grub; update-grub 2>/dev/null||true;fi

read -p "$(tr "Modify /etc/fstab? [y/N]: ")" CONFIRMA; [[! "$CONFIRMA" =~ ^[YySs] ]]&&exit 1
cp /etc/fstab "$FSTAB_BACKUP"; echo "# Backup: $FSTAB_BACKUP" >> /etc/fstab

EXT4_FOUND="/home";
CAJA_PATH="$EXT4_FOUND/$CAJA_DIR"; CAJA_MOUNT_PATH="$EXT4_FOUND/$CAJA_MOUNT"
mkdir -p "$CAJA_PATH" "$CAJA_MOUNT_PATH" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR" "$USER_HOME/Translations"
chown -R "$USER_NAME:$USER_NAME" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR" "$USER_HOME/Translations"

cat > "$ICON_DIR/cajasegura-open.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48"><rect x="2" y="2" width="44" height="44" rx="10" fill="url(#g)"/><path fill="$ACCENT_OPEN" d="M24 18c-3.3 0-6 2.7-6 6v4h12v-4c0-3.3-2.7-6-6-6z"/></svg>
SVG
cat > "$ICON_DIR/cajasegura-close.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48"><rect x="2" y="2" width="44" height="44" rx="10" fill="url(#g)"/><path fill="$ACCENT_CLOSE" d="M24 18c-3.3 0-6 2.7-6 6v4h12v-4c0-3.3-2.7-6-6-6z"/></svg>
SVG
chown "$USER_NAME:$USER_NAME" "$ICON_DIR"/*.svg

[! -f "$CAJA_PATH/gocryptfs.conf" ]&&{ read -p "$(tr "Initialize gocryptfs vault? [y/N]: ")" C; [[ "$C" =~ ^[YySs] ]]&&sudo -u "$USER_NAME" gocryptfs -init "$CAJA_PATH"; }

cat > "$BIN_DIR/cajasegura-mount.sh" <<'EOF'
#!/bin/bash
source "$HOME/.cache/Setup_Automount_CajaSegura_zswap_i18n.sh" 2>/dev/null
PASS=$(zenity --password --title="$(tr "CajaSegura Automount Installer")");echo $PASS|gocryptfs "$1" "$2"&&xdg-open "$2"&&notify-send -i cajasegura-open "$(tr "CajaSegura Opened")"
EOF
chmod +x "$BIN_DIR/cajasegura-mount.sh"; chown "$USER_NAME:$USER_NAME" "$BIN_DIR/cajasegura-mount.sh"

cat > "$BIN_DIR/cajasegura-umount.sh" <<'EOF'
#!/bin/bash
source "$HOME/.cache/Setup_Automount_CajaSegura_zswap_i18n.sh" 2>/dev/null
fusermount -u "$1" 2>/dev/null&&notify-send -i cajasegura-close "$(tr "CajaSegura Closed")"
EOF
chmod +x "$BIN_DIR/cajasegura-umount.sh"; chown "$USER_NAME:$USER_NAME" "$BIN_DIR/cajasegura-umount.sh"

cat > "$DESKTOP_DIR/cajasegura-open.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$(tr "Open CajaSegura")
Exec=$BIN_DIR/cajasegura-mount.sh $CAJA_PATH $CAJA_MOUNT_PATH
Icon=cajasegura-open
Terminal=false
Categories=Utility;Security;
EOF

cat > "$DESKTOP_DIR/cajasegura-close.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$(tr "Close CajaSegura")
Exec=$BIN_DIR/cajasegura-umount.sh $CAJA_MOUNT_PATH
Icon=cajasegura-close
Terminal=false
Categories=Utility;Security;
EOF
chown "$USER_NAME:$USER_NAME" "$DESKTOP_DIR"/*.desktop; actualizar_menu

DE="$XDG_CURRENT_DESKTOP"; [ "$INSTALL_PANEL" = true ]&&RUN="force"||read -p "$DE. $(tr "Add CajaSegura launchers to panel? [Y/n]: ")" RUN
[[! "$RUN" =~ ^[Nn] ]]&&[ -f "$SCRIPT_DIR/add_${DE,,}_launchers.sh" ]&&bash "$SCRIPT_DIR/add_${DE,,}_launchers.sh"
[ -n "$I3SOCK" -o -n "$SWAYSOCK" ]&&bash "$SCRIPT_DIR/add_i3_rofi.sh"

log "$(tr "Done. Reboot to apply")"

# aguante godoy cruz
