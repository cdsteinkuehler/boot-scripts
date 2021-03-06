#!/bin/bash -e
#
# Copyright (c) 2013-2014 Robert Nelson <robertcnelson@gmail.com>
# Portions copyright (c) 2014 Charles Steinkuehler <charles@steinkuehler.net>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

#This script assumes, these packages are installed, as network may not be setup
#dosfstools initramfs-tools rsync u-boot-tools

if ! id | grep -q root; then
	echo "must be run as root"
	exit
fi

# Check to see if we're starting as init
unset RUN_AS_INIT
if grep -q '[ =/]init-eMMC-flasher.sh\>' /proc/cmdline ; then
	RUN_AS_INIT=1

	root_drive="$(sed 's:.*root=/dev/\([^ ]*\):\1:;s/[ $].*//' /proc/cmdline)"
	boot_drive="${root_drive%?}1"

	mount /dev/$boot_drive /boot/uboot -o ro
	mount -t tmpfs tmpfs /tmp
else
	unset boot_drive
	boot_drive=$(LC_ALL=C lsblk -l | grep "/boot/uboot" | awk '{print $1}')

	if [ "x${boot_drive}" = "x" ] ; then
		echo "Error: script halting, system unrecognized..."
		exit 1
	fi
fi

if [ "x${boot_drive}" = "xmmcblk0p1" ] ; then
	source="/dev/mmcblk0"
	destination="/dev/mmcblk1"
fi

if [ "x${boot_drive}" = "xmmcblk1p1" ] ; then
	source="/dev/mmcblk1"
	destination="/dev/mmcblk0"
fi

flush_cache () {
	sync
}

flush_cache_mounted () {
	sync
	blockdev --flushbufs ${destination}
}

inf_loop () {
	while read MAGIC ; do
		case $MAGIC in
		beagleboard.org)
			echo "Your foo is strong!"
			bash -i
			;;
		*)	echo "Your foo is weak."
			;;
		esac
	done
}

# umount does not like device names without a valid /etc/mtab
# find the mount point from /proc/mounts
dev2dir () {
	grep -m 1 '^$1 ' /proc/mounts | while read LINE ; do set -- $LINE ; echo $2 ; done
}

write_failure () {
	echo "writing to [${destination}] failed..."

	[ -e /proc/$CYLON_PID ]  && kill $CYLON_PID > /dev/null 2>&1

	if [ -e /sys/class/leds/beaglebone\:green\:usr0/trigger ] ; then
		echo heartbeat > /sys/class/leds/beaglebone\:green\:usr0/trigger
		echo heartbeat > /sys/class/leds/beaglebone\:green\:usr1/trigger
		echo heartbeat > /sys/class/leds/beaglebone\:green\:usr2/trigger
		echo heartbeat > /sys/class/leds/beaglebone\:green\:usr3/trigger
	fi
	echo "-----------------------------"
	flush_cache
	umount $(dev2dir ${destination}p1) > /dev/null 2>&1 || true
	umount $(dev2dir ${destination}p2) > /dev/null 2>&1 || true
	inf_loop
}

umount_p1 () {
	DIR=$(dev2dir ${destination}p1)
	if [ -n "$DIR" ] ; then
		umount ${DIR} || umount -l ${DIR} || write_failure
	fi
}

umount_p2 () {
	DIR=$(dev2dir ${destination}p2)
	if [ -n "$DIR" ] ; then
		umount ${DIR} || umount -l ${DIR} || write_failure
	fi
}

check_running_system () {
	if [ ! -f /boot/uboot/uEnv.txt ] ; then
		echo "Error: script halting, system unrecognized..."
		echo "unable to find: [/boot/uboot/uEnv.txt] is ${source}p1 mounted?"
		inf_loop
	fi

	echo "-----------------------------"
	echo "debug copying: [${source}] -> [${destination}]"
	lsblk
	echo "-----------------------------"

	if [ ! -b "${destination}" ] ; then
		echo "Error: [${destination}] does not exist"
		write_failure
	fi
}

cylon_leds () {
	if [ -e /sys/class/leds/beaglebone\:green\:usr0/trigger ] ; then
		BASE=/sys/class/leds/beaglebone\:green\:usr
		echo none > ${BASE}0/trigger
		echo none > ${BASE}1/trigger
		echo none > ${BASE}2/trigger
		echo none > ${BASE}3/trigger

		STATE=1
		while : ; do
			case $STATE in
			1)	echo 255 > ${BASE}0/brightness
				echo 0   > ${BASE}1/brightness
				STATE=2
				;;
			2)	echo 255 > ${BASE}1/brightness
				echo 0   > ${BASE}0/brightness
				STATE=3
				;;
			3)	echo 255 > ${BASE}2/brightness
				echo 0   > ${BASE}1/brightness
				STATE=4
				;;
			4)	echo 255 > ${BASE}3/brightness
				echo 0   > ${BASE}2/brightness
				STATE=5
				;;
			5)	echo 255 > ${BASE}2/brightness
				echo 0   > ${BASE}3/brightness
				STATE=6
				;;
			6)	echo 255 > ${BASE}1/brightness
				echo 0   > ${BASE}2/brightness
				STATE=1
				;;
			*)	echo 255 > ${BASE}0/brightness
				echo 0   > ${BASE}1/brightness
				STATE=2
				;;
			esac
			sleep 0.1
		done
	fi
}

update_boot_files () {
	#We need an initrd.img to find the uuid partition, generate one if not present
	if [ ! -f /tmp/boot/initrd.img-$(uname -r) ] ; then
		if [ "${RUN_AS_INIT}" ] ; then
			# Writable locations required for update-initramfs
			[ -d /var/tmp ] && mount -t tmpfs tmpfs /var/tmp
			[ -d /var/lib/initramfs-tools/ ] && mount -t tmpfs tmpfs /var/lib/initramfs-tools/
		fi

		update-initramfs -c -k $(uname -r) -b /tmp/boot/ || write_failure

		if [ "${RUN_AS_INIT}" ] ; then
			umount /var/tmp
			umount /var/lib/initramfs-tools/
		fi
	fi

	if [ ! -f /tmp/boot/initrd.img ] ; then
		cp -v /tmp/boot/initrd.img-$(uname -r) /tmp/boot/initrd.img || write_failure
	fi

	# We should have a zImage-<version> file.  If one doesn't exist, assume we
	# booted from the /boot/uboot/zImage kernel file and give it a full name
	if [ -r /boot/uboot/zImage -a ! -f /tmp/boot/zImage-$(uname -r) ] ; then
		cp /boot/uboot/zImage /tmp/boot/zImage-$(uname -r) || write_failure
	fi
}

fdisk_toggle_boot () {
	fdisk ${destination} <<-__EOF__
	a
	1
	w
	__EOF__
	flush_cache
}

format_boot () {
	LC_ALL=C fdisk -l ${destination} | grep ${destination}p1 | grep '*' || fdisk_toggle_boot

	mkfs.vfat -F 16 ${destination}p1 -n boot
	flush_cache
}

format_root () {
	mkfs.ext4 ${destination}p2 -L rootfs
	flush_cache
}

repartition_drive () {
	dd if=/dev/zero of=${destination} bs=1M count=16
	flush_cache

	#96Mb fat formatted boot partition
	LC_ALL=C sfdisk --force --in-order --Linux --unit M "${destination}" <<-__EOF__
		1,96,0xe,*
		,,,-
	__EOF__
}

partition_drive () {
	flush_cache
	umount_p1
	umount_p2

	NUM_MOUNTS=$(mount | grep -v none | grep "${destination}" | wc -l)

	for ((i=1;i<=${NUM_MOUNTS};i++))
	do
		DRIVE=$(mount | grep -v none | grep "${destination}" | tail -1 | awk '{print $1}')
		umount ${DRIVE} >/dev/null 2>&1 || umount -l ${DRIVE} >/dev/null 2>&1 || write_failure
	done

	flush_cache
	repartition_drive
	flush_cache

	format_boot
	format_root
}

copy_boot () {
	mkdir -p /tmp/boot/ || true
	mount ${destination}p1 /tmp/boot/ -o sync
	#Make sure the BootLoader gets copied first:
	cp -v /boot/uboot/MLO /tmp/boot/MLO || write_failure
	flush_cache_mounted

	cp -v /boot/uboot/u-boot.img /tmp/boot/u-boot.img || write_failure
	flush_cache_mounted

	rsync -aAXv /boot/uboot/ /tmp/boot/ --exclude={MLO,u-boot.img,*bak,flash-eMMC.txt,flash-eMMC.log} || write_failure
	flush_cache_mounted

	update_boot_files
	flush_cache_mounted

	# Fixup uEnv.txt
	if [ -e /tmp/boot/target-uEnv.txt ] ; then
		# Use target version of uEnv.txt if it exists
		mv /tmp/boot/target-uEnv.txt /tmp/boot/uEnv.txt
	else
		# ...otherwise, just switch init back to systemd
		sed -i 's:^systemd.*init-eMMC-flasher.*$:systemd=init=/lib/systemd/systemd:' /tmp/boot/uEnv.txt
	fi
	flush_cache_mounted

	unset root_uuid
	root_uuid=$(/sbin/blkid -s UUID -o value ${destination}p2)
	if [ "${root_uuid}" ] ; then
		root_uuid="UUID=${root_uuid}"
		device_id=$(cat /tmp/boot/uEnv.txt | grep mmcroot | grep mmcblk | awk '{print $1}' | awk -F '=' '{print $2}')
		if [ ! "${device_id}" ] ; then
			device_id=$(cat /tmp/boot/uEnv.txt | grep mmcroot | grep UUID | awk '{print $1}' | awk -F '=' '{print $3}')
			device_id="UUID=${device_id}"
		fi
		sed -i -e 's:'${device_id}':'${root_uuid}':g' /tmp/boot/uEnv.txt
	else
		root_uuid="${source}p2"
	fi

	flush_cache_mounted
	umount_p1
}

copy_rootfs () {
	mkdir -p /tmp/rootfs/ || true
	mount ${destination}p2 /tmp/rootfs/ -o async,noatime
	rsync -aAXv /* /tmp/rootfs/ --exclude={/dev/*,/proc/*,/sys/*,/tmp/*,/run/*,/mnt/*,/media/*,/lost+found,/boot/*,/lib/modules/*} || write_failure
	flush_cache_mounted

	if [ -f /tmp/rootfs/opt/scripts/images/beaglebg.jpg ] ; then
		if [ -f /tmp/rootfs/opt/desktop-background.jpg ] ; then
			rm -f /tmp/rootfs/opt/desktop-background.jpg || true
		fi
		cp -v /tmp/rootfs/opt/scripts/images/beaglebg.jpg /tmp/rootfs/opt/desktop-background.jpg
	fi
	flush_cache_mounted

	mkdir -p /tmp/rootfs/boot/uboot/ || true
	mkdir -p /tmp/rootfs/lib/modules/$(uname -r)/ || true
	rsync -aAXv /lib/modules/$(uname -r)/* /tmp/rootfs/lib/modules/$(uname -r)/ || write_failure
	flush_cache_mounted

	if [ -r /boot/initrd.img-$(uname -r) ] ; then
		cp /boot/initrd.img-$(uname -r) /tmp/rootfs/boot/ || write_failure
		flush_cache_mounted
	fi

	unset boot_uuid
	boot_uuid=$(/sbin/blkid -s UUID -o value ${destination}p1)
	if [ "${boot_uuid}" ] ; then
		boot_uuid="UUID=${boot_uuid}"
	else
		boot_uuid="${source}p1"
	fi

	echo "# /etc/fstab: static file system information." > /tmp/rootfs/etc/fstab
	echo "#" >> /tmp/rootfs/etc/fstab
	echo "# Auto generated by: beaglebone-black-eMMC-flasher.sh" >> /tmp/rootfs/etc/fstab
	echo "#" >> /tmp/rootfs/etc/fstab
	echo "${root_uuid}  /  ext4  noatime,errors=remount-ro  0  1" >> /tmp/rootfs/etc/fstab
	echo "${boot_uuid}  /boot/uboot  auto  defaults  0  0" >> /tmp/rootfs/etc/fstab
	echo "debugfs         /sys/kernel/debug  debugfs  defaults          0  0" >> /tmp/rootfs/etc/fstab
	flush_cache_mounted
	umount_p2

	[ -e /proc/$CYLON_PID ]  && kill $CYLON_PID

	if [ -e /sys/class/leds/beaglebone\:green\:usr0/trigger ] ; then
		echo default-on > /sys/class/leds/beaglebone\:green\:usr0/trigger
		echo default-on > /sys/class/leds/beaglebone\:green\:usr1/trigger
		echo default-on > /sys/class/leds/beaglebone\:green\:usr2/trigger
		echo default-on > /sys/class/leds/beaglebone\:green\:usr3/trigger
	fi

	echo ""
	echo "This script has now completed it's task"
	echo "-----------------------------"
	echo "Note: Actually unpower the board, a reset [sudo reboot] is not enough."
	echo "-----------------------------"

	inf_loop
#	echo "Shutting Down..."
#	sync
#	halt
}

check_running_system
cylon_leds & CYLON_PID=$!
partition_drive
copy_boot
copy_rootfs
