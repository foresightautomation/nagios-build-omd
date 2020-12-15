#!/bin/bash
#
TOPDIR=$(realpath $(dirname $0)/..)
. $TOPDIR/etc/omd-build.env || exit 1
STARTDIR=$(pwd)

LOGFILE=$TOPDIR/$PROG.$TIMESTAMP.log

usage() {
    xval=$1
	shift
	[[ $@ ]] && echo "$@"
	echo "usage: OPTIONS {site1} [site2 ...]

Create a new OMD naemon site, configure NSCA and LiveStatus.

Options:
--------
    -h
	    Show this help.
"
    exit $xval
}

TMPF1=
TMP_NSCA_PORTS=
TMP_LIVE_PORTS=
cleanup() {
	/bin/rm -f $TMPF1 $TMP_NSCA_PORTS $TMP_LIVE_PORTS
}
trap cleanup 0
TMPF1=$(mktemp /tmp/XXXXXXXX)
TMP_NSCA_PORTS=$(mktemp /tmp/XXXXXXXX)
TMP_LIVE_PORTS=$(mktemp /tmp/XXXXXXXX)

while getopts h c ; do
    case "$c" in
	    h ) usage 0 ;;
		-- ) break ;;
		* ) usage 2 unknown option ;;
	esac
done
shift $(( OPTIND - 1 ))

if [[ $# -le 0 ]]; then
    usage 2 "No site specified."
fi

# Run an osm command for the site
# run_osm site command ...
run_omd() {
    typeset _site=$1
	shift
	echo "omd $@" | omd su $_site | egrep -v '^Last login'
}

# Grab a list of all of the NSCA and LIVESTATUS ports.
for i in $(omd sites | awk '$NR > 1 { print $1 }'); do
    run_omd $i "config show NSCA_TCP_PORT" 2>/dev/null >> $TMP_NSCA_PORTS
    run_omd $i "config show LIVESTATUS_TCP_PORT" 2>/dev/null >> $TMP_LIVE_PORTS
done
sed -i -e '/Last login/d' -e '/^$/d' $TMP_NSCA_PORTS
sed -i -e '/Last login/d' -e '/^$/d' $TMP_LIVE_PORTS

# Process each of the sites passed in.
for site in "$@" ; do
    echo ""
	date >> $LOGFILE
	section "Working on $site ..." | tee -a $LOGFILE
	
	# See if it exists
	# We exit 1 from awk if we DO find it.
	if ! omd sites | awk '$1 == "'$site'" { exit(1); }' ; then
	    out "Site exists.  Skipping."
		continue
	fi
	omd create fsa >> $TMPF1 2>&1
	if [[ $? -ne 0 ]]; then
		cat $TMPF1
		continue
	fi
	cat $TMPF1 | tee -a $LOGFILE
	SITE_HOME=$(getent passwd $site | awk -F: '{ print $6 }')

	# For now, NSCA is good enough.
	run_omd $site config set NSCA on
	MYPORT=5667
	while grep -w -q $MYPORT $TMP_NSCA_PORTS ; do
	    MYPORT=$(( MYPORT + 1 ))
	done
	echo "$MYPORT" >> $TMP_NSCA_PORTS
	out "Setting NSCA port to $MYPORT" | tee -a $LOGFILE
	run_omd $site config set NSCA_TCP_PORT $MYPORT

	out "Adding port to firewall"
	firewall-cmd --permanent --add-port=$MYPORT/tcp

	# Add live status
	run_omd $site config set LIVESTATUS_TCP on
	MYPORT=6557
	while grep -w -q $MYPORT $TMP_LIVE_PORTS ; do
	    MYPORT=$(( MYPORT + 1 ))
	done
	echo "$MYPORT" >> $TMP_LIVE_PORTS
	out "Setting Livestatus port to $MYPORT" | tee -a $LOGFILE
	run_omd $site config set LIVESTATUS_TCP_PORT $MYPORT

	out "Adding port to firewall"
	firewall-cmd --permanent --add-port=$MYPORT/tcp
	firewall-cmd --reload

	out "Update the omdadmin web password"
	htpasswd $SITE_HOME/etc/htpasswd omdadmin

	out "Generating SSH key for git pulls"
	if [[ ! -d $SITE_HOME/.ssh ]] ; then
		mkdir $SITE_HOME/.ssh
	fi
	ssh-keygen -t rsa -N '' -q -f $SITE_HOME/.ssh/id_rsa
	chown -R $site.$site $SITE_HOME/.ssh
	chmod -R go-rwx $SITE_HOME/.ssh

	out "You will need to paste this as the deploy key for the"
	out "nagios-config repo:"
	cat $SITE_HOME/.ssh/id_rsa.pub
	read -p "Press ENTER after this is done to continue> " ANS

	out Finished with $site
done

section "Finished.  Logged to $LOGFILE"