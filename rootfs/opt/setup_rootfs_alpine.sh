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

#the host's PATH is inherited by the chroot and may be missing the sbin
#directories, which is where the alpine setup-* scripts live
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#set hostname and apk repos
setup-hostname "$hostname"
setup-apkrepos \
  "http://dl-cdn.alpinelinux.org/alpine/$release_name/main/" \
  "http://dl-cdn.alpinelinux.org/alpine/$release_name/community/"

#enable services on startup
rc-update add acpid default
rc-update add bootmisc boot
rc-update add crond default
rc-update add devfs sysinit
rc-update add sysfs sysinit
rc-update add dmesg sysinit
rc-update add hostname boot
rc-update add hwclock boot
rc-update add hwdrivers sysinit
rc-update add killprocs shutdown
rc-update add mdev sysinit
rc-update add modules boot
rc-update add mount-ro shutdown
rc-update add networking boot
rc-update add savecache shutdown
rc-update add seedrng boot
rc-update add swap boot
rc-update add syslog boot

#keep a persistent boot log so that boot problems can be debugged afterwards
#from the bootloader's rescue shell. klogd adds kernel messages to the syslog in
#/var/log/messages, and rc_logger saves openrc's output to /var/log/rc.log
rc-update add klogd boot
echo 'rc_logger="YES"' >> /etc/rc.conf

#add service to kill frecon
#this uses the same script as the systemd unit on debian, which also unmounts
#the /dev/console bind mount that the bootloader points at frecon's pty
cat > /etc/init.d/kill-frecon << 'END'
#!/sbin/openrc-run

description="kill frecon to allow xorg to start"

depend() {
  before display-manager
}

start() {
  ebegin "Killing frecon"
  /usr/local/bin/kill_frecon
  eend 0
}
END
chmod +x /etc/init.d/kill-frecon /usr/local/bin/kill_frecon
rc-update add kill-frecon boot

#setup the desktop
if echo "$packages" | grep "task-" >/dev/null; then
  desktop="$(echo $packages | cut -d'-' -f2)"
  setup-desktop $desktop

else
  apk add $packages
fi

#openrc doesnt work with /etc/modules-load.d for some reason 
#so we need to copy those to /etc/modules
module_files="$(ls /etc/modules-load.d)"
for mod_file in $module_files; do
  cat "/etc/modules-load.d/$mod_file" >> /etc/modules
  echo >> /etc/modules
done

#install base packages
if [ -z "$disable_base_pkgs" ]; then
  #install various packages
  apk add elogind polkit-elogind udisks2 polkit-elogind sudo zram-init networkmanager networkmanager-tui networkmanager-wifi network-manager-applet wpa_supplicant adw-gtk3 cloud-utils-growpart nano mousepad
  
  #start desktop services
  rc-update add networkmanager default
  rc-update add wpa_supplicant default
  rc-update add zram-init default
  rc-update add elogind default
  rc-update add dbus default

  #configure zram
  sed -i 's/=zstd/=lzo/' /etc/conf.d/zram-init #set lzo algorithm
  sed -i '/size0=512/d' /etc/conf.d/zram-init #disable default swap size
  sed -i '/blk1=1024/d' /etc/conf.d/zram-init #disable default /tmp block size
  echo "size0=\`LC_ALL=C free -m | awk '/^Mem:/{print int(\$2/2)}'\`" >> /etc/conf.d/zram-init #set swap size to half of physical

  #configure networkmanager
  mkdir -p /etc/NetworkManager/conf.d
  echo -e "[main]\nauth-polkit=false" > /etc/NetworkManager/conf.d/any-user.conf
fi

#elogind can't mount the per-user /run/user/$UID tmpfs on chrome os kernels,
#because it mounts via /proc/self/fd/N and the chromiumos lsm blocks mounts
#that traverse symlinks. on debian this is fixed by the patched systemd, but on
#alpine elogind fails to create the session, so logins get no XDG_RUNTIME_DIR.
#work around this by mounting the dir from pam before pam_elogind runs.
chmod +x /usr/local/bin/shimboot_rundir
rundir_hook="session optional pam_exec.so quiet /usr/local/bin/shimboot_rundir"
#alpine's linux-pam ships base-session (which lightdm includes for user logins)
#in /usr/lib/pam.d. files in /etc/pam.d take precedence, so copy them there
for pam_file in $(grep -l "pam_elogind.so" /usr/lib/pam.d/* 2>/dev/null); do
  if [ ! -e "/etc/pam.d/$(basename "$pam_file")" ]; then
    cp "$pam_file" /etc/pam.d/
  fi
done
for pam_file in $(grep -l "pam_elogind.so" /etc/pam.d/* 2>/dev/null); do
  if ! grep -q "shimboot_rundir" "$pam_file"; then
    sed -i "/pam_elogind\.so/i $rundir_hook" "$pam_file"
  fi
done

#alpine's lightdm (1.33) won't start x on a seat until logind reports it as
#graphical, which depends on elogind finding the gpu through eudev's tags.
#debian's lightdm (1.26) doesn't wait for this, so match the working debian setup
if [ -d /etc/lightdm ]; then
  mkdir -p /etc/lightdm/lightdm.conf.d
  printf '[LightDM]\nlogind-check-graphical=false\n' > /etc/lightdm/lightdm.conf.d/50-shimboot.conf
fi

#x draws the screen through mesa (glamor), and alpine edge's mesa is much newer
#than the rma shim kernels. on octopus the screen is never drawn while the
#cursor still moves, until x dies and lightdm restarts it, which looks like a
#gpu hang. turn off glamor so that x itself doesn't use the gpu.
if command -v Xorg >/dev/null 2>&1; then
  mkdir -p /etc/X11/xorg.conf.d
  cat > /etc/X11/xorg.conf.d/20-shimboot-noaccel.conf << 'END'
Section "Device"
  Identifier "shimboot-gpu"
  Driver "modesetting"
  Option "AccelMethod" "none"
EndSection
END
fi

if [ ! $username ]; then
  read -p "Enter the username for the user account: " username
fi
useradd -m $username
usermod -G netdev -a $username
usermod -G plugdev -a $username
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

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
  usermod -a -G wheel $username
fi

echo "Enter a user password:"
set_password "$username" "$user_passwd"
