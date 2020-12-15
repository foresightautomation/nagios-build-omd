#!/bin/bash
#
# Prep the system.
TOPDIR=$(realpath $(dirname $0)/..)
. $TOPDIR/etc/omd-build.env || exit 1
STARTDIR=$(pwd)

export USEPAUSE=0
while getopts p c ; do
    case "$c" in
	    p ) USEPAUSE=1 ;;
		* ) break ;;
	esac
done
shift $(( OPTIND - 1 ))

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
yum-config-manager --enable epel || exit 1

section "Installing Consol Labs repo"
yum -y -d 1 install https://labs.consol.de/repo/stable/rhel7/i386/labs-consol-stable.rhel7.noarch.rpm

# Now install the rest of the packages
PKGSFILE=$TOPDIR/etc/pkgs.list
if [[ -f $PKGSFILE ]] ; then
	section "installing dependency packages"
	egrep -v '#' $PKGSFILE | xargs yum -y -d 1 install || exit 1
fi

section "Downloading sources"
[[ -d $SRCDIR ]] || mkdir -p $SRCDIR || exit 1
cd $SRCDIR || exit 1

TDIR=$NRDP_TARDIR
SFILE=$NRDP_TARFILE
SRCURL="$NRDP_SRC"
if [[ ! -f $SFILE ]] ; then
	out "nrdp"
	wget --progress=dot:mega -O $SFILE "$SRCURL" || exit 1
fi
if [[ ! -d $TDIR ]]; then
	tar xzf $SFILE
fi
cd $STARTDIR

section "Finished."
