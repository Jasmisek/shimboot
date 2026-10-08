#!/bin/sh

#setup the alpine linux rootfs
#this is meant to be run within the chroot created by build_rootfs.sh

DEBUG="$1"
set -e
if [ "$DEBUG" ]; then
  set -x
fi

release_name="$2"
packages="$3"
hostname="$4"
root_passwd="$5"
username="$6"
user_passwd="$7"
enable_root="$8"
disable_base_pkgs="$9"
arch="${10}"

#set PATH to execute binaries in chroot
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#set hostname and apk repos
setup-hostname "$hostname"
setup-apkrepos \
  "http://dl-cdn.alpinelinux.org/alpine/$release_name/main/" \
  "http://dl-cdn.alpinelinux.org/alpine/$release_name/community/"

apk update

#enable core services on startup
rc-update add acpid default
rc-update add bootmisc boot
rc-update add crond default
rc-update add devfs sysinit
rc-update add sysfs sysinit
rc-update add dmesg sysinit
rc-update add hostname boot
rc-update add hwclock boot
rc-update add cgroups sysinit
rc-update add killprocs shutdown
rc-update add modules boot
rc-update add mount-ro shutdown
rc-update add networking boot
rc-update add savecache shutdown
rc-update add seedrng boot
rc-update add swap boot
rc-update add syslog boot

#add service to kill frecon before graphical display manager starts
#frecon-lite holds DRM master, so it must be killed before Xorg/Wayland can start
cat << 'EOF' > /etc/init.d/kill-frecon
#!/sbin/openrc-run

description="Kill frecon to allow display manager to acquire DRM master"

depend() {
  before display-manager lightdm sddm gdm greetd
}

start() {
  ebegin "Stopping frecon"
  /usr/local/bin/kill_frecon
  eend 0
}
EOF
chmod +x /etc/init.d/kill-frecon
rc-update add kill-frecon default

#setup the desktop
desktop=""
if echo "$packages" | grep "task-" >/dev/null; then
  desktop="$(echo $packages | cut -d'-' -f2)"
  if [ "$desktop" = "kde" ]; then
    desktop="plasma"
  elif [ "$desktop" = "lxde" ]; then
    desktop="lxqt"
  fi
  setup-desktop $desktop
elif [ -n "$packages" ]; then
  apk add $packages
fi

#install essential desktop helpers, Xorg utilities, and drivers
#NOTE: xf86-video-intel is intentionally NOT installed anymore. it is unmaintained,
#takes priority over the built-in modesetting driver whenever it is present, and on
#gen9+ GPUs (apollo lake etc) it requests the removed i965 DRI driver, which breaks X.
#the modesetting driver (built into xorg-server) + mesa iris is the correct stack.
apk add bash dbus-x11 xrandr xset setxkbmap mesa-dri-gallium xf86-input-libinput shadow ca-certificates

#intel GPU firmware (GuC/HuC/DMC). this package only exists on newer alpine releases,
#and shimboot may already copy firmware from the shim, so never fail the build over it
if [ "$arch" = "amd64" ] || [ "$arch" = "x86_64" ]; then
  apk add linux-firmware-i915 2>/dev/null || true
fi

#configure Xorg wrapper with root rights so non-root display manager can run Xorg without physical VT
mkdir -p /etc/X11
cat << 'EOF' > /etc/X11/Xwrapper.config
allowed_users=anybody
needs_root_rights=yes
EOF
chmod 644 /etc/X11/Xwrapper.config

#force the generic modesetting driver so a leftover/old DDX can never be picked
#if the screen is still gray, uncomment the AccelMethod line to disable glamor
mkdir -p /etc/X11/xorg.conf.d
cat << 'EOF' > /etc/X11/xorg.conf.d/20-modesetting.conf
Section "Device"
    Identifier "GPU0"
    Driver "modesetting"
    #Option "AccelMethod" "none"
EndSection
EOF
chmod 644 /etc/X11/xorg.conf.d/20-modesetting.conf

#openrc doesnt work with /etc/modules-load.d for some reason 
#so we need to copy those to /etc/modules
if [ -d /etc/modules-load.d ]; then
  module_files="$(ls /etc/modules-load.d)"
  for mod_file in $module_files; do
    cat "/etc/modules-load.d/$mod_file" >> /etc/modules
    echo >> /etc/modules
  done
fi

#install base packages
if [ -z "$disable_base_pkgs" ]; then
  #install various packages
  apk add elogind polkit-elogind udisks2 sudo zram-init networkmanager networkmanager-tui networkmanager-wifi network-manager-applet adw-gtk3 cloud-utils-growpart nano mousepad openssh-server openssh-client
  
  #start desktop services
  rc-update add networkmanager default
  rc-update add zram-init default
  rc-update add elogind default
  rc-update add dbus default
  rc-update add sshd default

  #allow password authentication for SSH in case user needs remote shell access
  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
  sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
  ssh-keygen -A 2>/dev/null || true

  #configure zram
  sed -i 's/=zstd/=lzo/' /etc/conf.d/zram-init 2>/dev/null || true #set lzo algorithm
  sed -i '/size0=512/d' /etc/conf.d/zram-init 2>/dev/null || true #disable default swap size
  sed -i '/blk1=1024/d' /etc/conf.d/zram-init 2>/dev/null || true #disable default /tmp block size
  echo "size0=\`LC_ALL=C free -m | awk '/^Mem:/{print int(\$2/2)}'\`" >> /etc/conf.d/zram-init #set swap size to half of physical

  #configure networkmanager
  mkdir -p /etc/NetworkManager/conf.d
  echo -e "[main]\nauth-polkit=false" > /etc/NetworkManager/conf.d/any-user.conf
fi

if [ ! "$username" ]; then
  read -p "Enter the username for the user account: " username
fi

#ensure necessary groups exist
for grp in wheel video audio input netdev plugdev autologin seat; do
  addgroup -S "$grp" 2>/dev/null || true
done

#add lightdm to video and input groups if lightdm is installed
if id lightdm >/dev/null 2>&1; then
  addgroup lightdm video 2>/dev/null || true
  addgroup lightdm input 2>/dev/null || true
fi

#create user with bash shell
if ! id "$username" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$username" 2>/dev/null || adduser -D -s /bin/bash "$username" 2>/dev/null || adduser -D "$username"
fi

for grp in wheel video audio input netdev plugdev autologin seat; do
  addgroup "$username" "$grp" 2>/dev/null || usermod -a -G "$grp" "$username" 2>/dev/null || true
done

echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

#configure display managers with autologin
if [ -d /etc/lightdm ] || which lightdm >/dev/null 2>&1; then
  mkdir -p /etc/lightdm/lightdm.conf.d
  session_name="${desktop:-xfce}"

  #make sure the autologin session actually exists, otherwise autologin fails and
  #lightdm bounces back to an empty gray screen. fall back to the first installed session
  if [ ! -f "/usr/share/xsessions/${session_name}.desktop" ]; then
    first_session="$(ls /usr/share/xsessions 2>/dev/null | head -n1)"
    if [ -n "$first_session" ]; then
      session_name="${first_session%.desktop}"
    fi
  fi

  #only set a session wrapper if it exists on this system. a wrong path makes every
  #login die instantly, so lightdm just keeps restarting. otherwise use lightdm's default
  session_wrapper_line=""
  if [ -x /etc/X11/xinit/Xsession ]; then
    session_wrapper_line="session-wrapper=/etc/X11/xinit/Xsession"
  fi

  cat << EOF > /etc/lightdm/lightdm.conf
[LightDM]
run-directory=/run/lightdm
logind-check-graphical=false

[Seat:*]
greeter-session=lightdm-gtk-greeter
${session_wrapper_line}
user-session=${session_name}
autologin-user=${username}
autologin-user-timeout=0
pam-service=lightdm
pam-autologin-service=lightdm-autologin
EOF
fi

if which sddm >/dev/null 2>&1; then
  mkdir -p /etc/sddm.conf.d
  cat << EOF > /etc/sddm.conf.d/autologin.conf
[Autologin]
User=${username}
Session=${desktop:-plasma}
EOF
fi

set_password() {
  local user="$1"
  local password="$2"
  if [ ! "$password" ]; then
    while ! passwd $user; do
      echo "Failed to set password for $user, please try again."
    done
  else
    yes "$password" | passwd $user
  fi
}

if [ "$enable_root" ]; then 
  echo "Enter a root password:"
  set_password root "$root_passwd"
else
  addgroup "$username" wheel 2>/dev/null || true
fi

echo "Enter a user password:"
set_password "$username" "$user_passwd"

#enable bash greeter
if [ -d "/home/$username" ]; then
  echo "/usr/local/bin/shimboot_greeter" >> "/home/$username/.bashrc"
  echo "/usr/local/bin/shimboot_greeter" >> "/home/$username/.profile"
fi
