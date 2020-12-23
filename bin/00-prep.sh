#!/bin/bash
#
# Prep the system.
TOPDIR=$(realpath $(dirname $0)/..)
. $TOPDIR/etc/omd-build.env || exit 1
STARTDIR=$(pwd)

section "Disabling SELINUX"
sed -i -e 's/SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
setenforce 0

section "installing yum-utils and updates"
yum -y -d 1 install yum-utils deltarpm || exit 1
yum-config-manager --enable "Optional*" || exit 1
yum -y -d 1 update || exit 1

# Install the EPEL release
section "installing and enabling epel"
case "$OS_ID" in
	amzn ) amazon-linux-extras install epel -y ;;
	* ) yum -y -d 1 install epel-release
esac
yum-config-manager --enable epel >/dev/null || exit 1

section "Installing Consol Labs repo"
yum -y -d 1 install https://labs.consol.de/repo/stable/rhel7/i386/labs-consol-stable.rhel7.noarch.rpm

# Now install the rest of the packages
PKGSFILE=$TOPDIR/etc/pkgs.list
if [[ -f $PKGSFILE ]] ; then
	section "installing dependency packages"
	# there are so many here, the '-d 1' has been removed so
	# it doesn't look like it's hanging
	egrep -v '#' $PKGSFILE | xargs yum -y install || exit 1
fi

# Add HTTP to the firewall
if [[ "$OS_ID" != "amzn" ]]; then
	section "Adding HTTP/HTTPS to firewall"
	firewall-cmd --permanent --add-service=http
	firewall-cmd --permanent --add-service=https
	firewall-cmd --reload
fi

section "Finished."
