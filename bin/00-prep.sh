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

section "Installing Foresight Automation repo"
yum install http://yum.fsautomation.com/fsatools-release-centos7.noarch.rpm

# Now install the rest of the packages
PKGSFILE=$TOPDIR/etc/pkgs.list
if [[ -f $PKGSFILE ]] ; then
	section "installing dependency packages"
	# there are so many here, the '-d 1' has been removed so
	# it doesn't look like it's hanging
	egrep -v '#' $PKGSFILE | xargs yum -y install || exit 1
fi

# If we're not on amzn linux, install haveged, which provides
# entropy.
if [[ "$OS_ID" != "amzn" ]]; then
	yum -y install haveged
	systemctl enable haveged
	systemctl start haveged
fi

# Add HTTP to the firewall
if [[ "$OS_ID" != "amzn" ]]; then
	section "Adding HTTP/HTTPS to firewall"
	firewall-cmd --permanent --add-service=http
	firewall-cmd --permanent --add-service=https
	firewall-cmd --reload
fi

# Update the php.ini file
section "Checking the /etc/php.ini file"
DST=/etc/php.ini
BKUP=$DST.$TIMESTAMP
if ! egrep -q '^date.timezone' $DST ; then
	out "  updating timezone"
	set_timezone() {
		TIMEZONE="$TZ"
		[[ -n "$TIMEZONE" ]] && return 0
		TIMEZONE=$(timedatectl | grep 'Time zone' | awk '{ print $3 }')
		[[ -n "$TIMEZONE" && "$TIMEZONE" =~ ^America ]] && return 0
		TIMEZONE=$(readlink /etc/localtime 2>/dev/null | sed -e 's,^.zoneinfo/,,')
		[[ -n "$TIMEZONE" ]] && return 0
		return 1
	}

	if ! set_timezone ; then
		out "  could not determine timezone"
		read -p "Enter Timezone: " TIMEZONE
	fi
	if [[ -n "$TIMEZONE" ]]; then
		[[ -f $BKUP ]] || cp $DST $BKUP
		sed -i -e "/;date.timezone/a date.timezone = \"$TIMEZONE\"" \
			$DST
	else
		out "  skipping timezone."
	fi
fi


section "Finished."
