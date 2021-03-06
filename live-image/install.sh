#!/bin/sh
# This script installs DOMjudge specific stuff to a cleanly installed
# Debian image. It assumes that the Debian system is reachable via
# SSH; it copies the necessary files and then runs the installation
# script there.

# Run this script as:
# $ install.sh <hostname> [options]
#
# options:
#  -p <proxy>     APT proxy URL to use during installation
#  -v <version>   Debian package version of DOMjudge to install

set -e

EXTRA=/tmp/extra-files.tgz

CHROOTDIR=/var/lib/domjudge/javachroot

# Check if this script is started from the host:
if [ "$1" != "ON_TARGET" ]; then
	if [ -z "$1" ]; then
		echo "Error: no target hostname specified."
		exit 1
	fi
	TARGET="$1"
	shift
	make -C `dirname $0` `basename $EXTRA`
	scp "$0" `dirname $0`/`basename $EXTRA` "root@$TARGET:`dirname $EXTRA`"
	ssh "root@$TARGET" "/tmp/`basename $0` ON_TARGET $@"
	exit 0
fi

# We're on the target system here, skip first argument 'ON_TARGET':
shift

while getopts ':p:v:' OPT ; do
	case $OPT in
		p)	DEBPROXY="$OPTARG" ;;
		v)	DJDEBVERSION="$OPTARG" ;;
		:)
			echo "Error: option '$OPTARG' requires an argument."
			exit 1
			;;
		?)
			echo "Error: unknown option '$OPTARG'."
			exit 1
			;;
		*)
			echo "Error: unknown error reading option '$OPT', value '$OPTARG'."
			exit 1
			;;
	esac
done
shift $((OPTIND-1))

export DEBPROXY DJDEBVERSION

# Unpack extra files:
cd /
tar xzf $EXTRA
rm -f $EXTRA

export DEBIAN_FRONTEND=noninteractive

# Add DOMjudge Debian archive key:
echo -n "Adding DOMjudge APT archive key... "
apt-key add /tmp/domjudge-apt-key.asc
apt-get -q update
apt-get -q -y upgrade

echo 'APT::Install-Recommends "false";' >> /etc/apt/apt.conf

# Fix some GRUB boot loader settings:
sed -i -e 's/^\(GRUB_DEFAULT\)=.*/\1=2/' \
       -e 's/^\(GRUB_TIMEOUT\)=.*/\1=15/' \
       -e 's/^#\(GRUB_\(DISABLE.*_RECOVERY\|INIT_TUNE\)\)/\1/' \
       -e '/GRUB_GFXMODE/a GRUB_GFXPAYLOAD_LINUX=1024x786,640x480' \
	/etc/default/grub
update-grub

# Mount /tmp as tmpfs:
sed -i '/^proc/a tmpfs		/tmp		tmpfs	size=512M,mode=1777	0	0' /etc/fstab

# Enable Bash autocompletion and ls colors:
sed -i '/^#if \[ -f \/etc\/bash_completion/,/^#fi/ s/^#//' /etc/bash.bashrc
sed -i '/^# *export LS_OPTIONS/,/^# *alias ls=/ s/^# *//' /root/.bashrc

# Disable persistent storage and network udev rules:
cd /lib/udev/rules.d
mkdir disabled
mv 75-persistent-net-generator.rules disabled
cd -

# Pregenerate random password for DOMjudge database, so that we can
# set it the same for domserver and judgehost packages:
DBPASSWORD=`head -c12 /dev/urandom | base64 | head -c 16 | tr '/+' 'Aa'`

# Install packages including DOMjudge:
debconf-set-selections <<EOF
mysql-server-5.1	mysql-server/root_password	password	domjudge
mysql-server-5.1	mysql-server/root_password_again		password	domjudge

phpmyadmin	phpmyadmin/mysql/admin-user	string	root
phpmyadmin	phpmyadmin/mysql/admin-pass	password	domjudge
phpmyadmin	phpmyadmin/reconfigure-webserver	multiselect	apache2
phpmyadmin	phpmyadmin/database-type	select	mysql

domjudge-domserver	domjudge-domserver/mysql/app-pass       password	$DBPASSWORD
domjudge-domserver	domjudge-domserver/app-password-confirm	password	$DBPASSWORD
domjudge-domserver	domjudge-domserver/dbconfig-install	boolean	true
domjudge-domserver	domjudge-domserver/mysql/admin-user	string	root
domjudge-domserver	domjudge-domserver/mysql/admin-pass	password	domjudge

domjudge-judgehost	domjudge-judgehost/mysql/app-pass       password	$DBPASSWORD
domjudge-judgehost	domjudge-judgehost/app-password-confirm	password	$DBPASSWORD
domjudge-judgehost	domjudge-judgehost/dbconfig-install	boolean	true
domjudge-judgehost	domjudge-judgehost/mysql/admin-user	string	root
domjudge-judgehost	domjudge-judgehost/mysql/admin-pass	password	domjudge

EOF

apt-get install -q -y \
	apt-transport-https \
	openssh-server mysql-server apache2 sudo \
	gcc g++ openjdk-7-jdk openjdk-7-jre-headless fp-compiler ghc \
	python-minimal python3-minimal gnat gfortran lua5.1 \
	mono-gmcs ntp phpmyadmin debootstrap cgroup-bin libcgroup1 \
	enscript lpr zip unzip

# Use DOMjudge debian packages if present under /tmp:
if [ -f /tmp/domjudge-domserver_*.deb ]; then
	dpkg -i /tmp/domjudge-common_*.deb    /tmp/domjudge-doc_*.deb \
	        /tmp/domjudge-domserver_*.deb /tmp/domjudge-judgehost_*.deb \
	|| apt-get -q -y -f install
else
	USEVERSION="${DJDEBVERSION:+=$DJDEBVERSION}"
	apt-get install -q -y \
	        domjudge-domserver${USEVERSION} domjudge-doc${USEVERSION} \
	        domjudge-judgehost${USEVERSION}
fi

# Do not have stuff listening that we don't use:
apt-get remove -q -y --purge portmap nfs-common

# Generate REST API password and set it for judgehost user:
cd /etc/domjudge/
./genrestapicredentials > restapi.secret
RESTPW=`tail -n1 restapi.secret | sed 's/.*[[:space:]]//'`
echo "UPDATE \`user\` SET \`password\` = MD5('judgehost#$RESTPW') \
WHERE \`username\` = 'judgehost';" >> /tmp/mysql_db_livedata.sql
cd -

# Add DOMjudge-live specific and sample DB content:
cat /tmp/mysql_db_livedata.sql \
    /usr/share/domjudge/sql/mysql_db_examples.sql \
    /usr/share/domjudge/sql/mysql_db_files_examples.sql \
| mysql -u root --password=domjudge domjudge

# Configure domserver/judgehost systemd target (aka. "runlevels"):
systemctl set-default multi-user.target
systemctl disable apache2.service mysql.service domjudge-judgehost.service

# Make some files available in the doc root
ln -s /usr/share/doc/domjudge-doc/examples/*.pdf      /var/www/html/
ln -s /usr/share/domjudge/www/images/DOMjudgelogo.png /var/www/html/

# Fix chroot build script to install CA certificates before trying to
# copy files into /etc/ssl and don't try to chmod file that doesn't
# exist in Debian Jessie:
sed -i 's/^\(INCLUDEDEBS=".*\)"$/\1,ca-certificates"/' /usr/sbin/dj_make_chroot
sed -i 's, /usr/lib/pt_chown,,' /usr/sbin/dj_make_chroot

# Build DOMjudge chroot environment:
dj_make_chroot

# Add packages to chroot for additional language support
mount --bind /proc $CHROOTDIR/proc
chroot $CHROOTDIR /bin/sh -c \
	"apt-get -q -y install python-minimal python3-minimal mono-gmcs \
		bash-static gnat gfortran lua5.1"
umount $CHROOTDIR/proc
# Copy (static) bash binary to location that is available within chroot
cp -a $CHROOTDIR/bin/bash-static $CHROOTDIR/usr/local/bin/bash

# Workaround: put nameserver in chroot, it will otherwise have the nameserver
# of the build system which will not work elsewhere.
echo "nameserver 8.8.8.8" > $CHROOTDIR/etc/resolv.conf

# Add extra domjudge-run-X users for running multiple judgedaemons:
for i in 0 1 2 3 ; do
	adduser --quiet --system domjudge-run-$i --home /nonexistent --no-create-home
done

# Add domjudge,domjudge-run users to chroot:
# FIXME: needed for Python when $HOME is set, fixed in DOMjudge >= 4.1
grep ^domjudge /etc/passwd >> $CHROOTDIR/etc/passwd
grep ^domjudge /etc/shadow >> $CHROOTDIR/etc/shadow

# Do some cleanup to prepare for creating a releasable image:
echo "Doing final cleanup, this can take a while..."
apt-get -q clean
rm -f /root/.ssh/authorized_keys /root/.bash_history

# Prebuild locate database:
/etc/cron.daily/mlocate

# Remove SSH host keys to regenerate them on next first boot:
rm -f /etc/ssh/ssh_host_*

# Replace /etc/issue with live image specifics:
mv /etc/issue /etc/issue.orig
cat > /etc/issue.djlive <<EOF
DOMjudge-live running on `cat /etc/issue.orig`

DOMjudge-live image generated on `date`
DOMjudge Debian package version `dpkg -s domjudge-common | sed -n 's/^Version: //p'`

EOF
cp /etc/issue.djlive /etc/issue.djlive-default-passwords
cat /tmp/domjudge-default-passwords >> /etc/issue.djlive-default-passwords
ln -s /etc/issue.djlive-default-passwords /etc/issue

# Unmount swap and zero empty space to improve compressibility:
swapoff -a
cat /dev/zero > /dev/sda1 2>/dev/null || true
cat /dev/zero > /zerofile 2>/dev/null || true
sync
rm -f /zerofile

# Recreate swap partition and use label to mount swap:
mkswap -L swap /dev/sda1
sed -i 's/^UUID=[a-z0-9-]* *\(.*swap.*\)$/LABEL=swap      \1/' /etc/fstab

echo "Done installing, halting system..."

halt
