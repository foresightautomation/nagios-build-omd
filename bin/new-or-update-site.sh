#!/bin/bash
#
TOPDIR=$(realpath $(dirname $0)/..)
. $TOPDIR/etc/omd-build.env || exit 1
STARTDIR=$(pwd)

LOGFILE=$TOPDIR/new-or-update.$TIMESTAMP.log

usage() {
    xval=$1
	shift
	[[ $@ ]] && echo "$@"
	echo "usage: OPTIONS {site1} [site2 ...]

Create a new OMD naemon site, and add NRDP configurations and
custom FSA scripts and config.

Options:
--------
    -h
	    Show this help.
"
    exit $xval
}

TMPF1=
cleanup() {
	/bin/rm -f $TMPF1
}
trap cleanup 0
TMPF1=$(mktemp /tmp/XXXXXXXX)

while getopts h c ; do
    case "$c" in
	    h ) usage 0 ;;
		-- ) break ;;
		* ) usage 2 unknown option ;;
	esac
done
shift $(( OPTIND - 1 ))

NRDPTOPDIR="$SRCDIR/$NRDP_TARDIR"
if [[ ! -d "$NRDPTOPDIR" ]]; then
    usage 2 "$NRDPTOPDIR - no such directory.  Run the prep script."
fi

if [[ $# -le 0 ]]; then
    usage 2 "No site specified."
fi

for site in "$@" ; do
    echo ""
	date >> $LOGFILE
	section "Working on $site ..." | tee -a $LOGFILE
	
	# See if it exists
	# We exit 1 from awk if we DO find it.
	if ! omd sites | awk '$1 == "'$site'" { exit(1); }' ; then
	    out "Site exists.  Updating."
	else
	    out "No such site.  Creating."
		omd create fsa >> $TMPF1 2>&1
		if [[ $? -ne 0 ]]; then
		    cat $TMPF1
			continue
		fi
		cat $TMPF1 >> $LOGFILE
	fi
	SITEHOME=$(getent passwd $site | awk -F: '{ print $6 }')
	if [[ -z "$SITEHOME" ]]; then
	    echo "ERROR: cannot get home directory for '$site' user"
		continue
	fi
	if [[ ! -d "$SITEHOME" ]]; then
	    echo "ERROR: $SITEHOME - no such directory."
		continue
	fi
	SITE_NRDP=$SITEHOME/share/nrdp
	if [[ ! -d "$SITE_NRDP" ]] ; then
		mkdir $SITE_NRDP || continue
		chown $site.$site $SITE_NRDP
	fi
	if [[ ! -d "$SITE_NRDP/server" ]] ; then
		mkdir $SITE_NRDP/server || continue
		chown $site.$site $SITE_NRDP/server
	fi
	out "Copying NRDP client files"
	rsync --chown ${site}:${site} -a --backup --suffix=".$TIMESTAMP" \
	    $NRDPTOPDIR/clients $NRDPTOPDIR/LICENSE* $NRDPTOPDIR/CHANGES* \
		$SITE_NRDP
	out "Copying NRDP common server files"
	rsync --chown ${site}:${site} -a --backup --suffix=".$TIMESTAMP" \
	    $NRDPTOPDIR/server/[i-p]* \
		$SITE_NRDP/server/.

	DST=$SITE_NRDP/server/config.inc.php
	if [[ ! -f $DST ]]; then
	    out "Creating $DST" | tee -a $LOGFILE
		NEWTOKEN=$(apg -m 12 -n 1)
		echo "Token=$NEWTOKEN" | tee -a $LOGFILE
		# We will append our new token after the example token
		sed -e '/90dfs7jwn3/a  "'$NEWTOKEN'",' \
			-e "s/nagcmd/$site/" \
			-e "s,/usr/local/nagios,$SITEHOME,g" \
			-e 's,/var/rw/nagios.cmd,/tmp/run/naemon.cmd,' \
			-e 's,/var/spool/checkresults,/tmp/naemon/checkresults,' \
			-e "s,/usr/local/nrdp,$SITE_NRDP,g" \
			$NRDPTOPDIR/server/config.inc.php > $DST
		chmod 640 $DST
		chown ${site}.${site} $DST
	fi

	out "Checking http config file"
	# Generate a new one into $TMPF1
	# This is a very basic file.
	cat > $TMPF1 <<EOF
Alias /$site/nrdp /omd/sites/$site/share/nrdp/server
<Directory "/omd/sites/$site/share/nrdp">
   Options None
   AllowOverride None
   <RequireAll>
	   Require all granted
   </RequireAll>
</Directory>
EOF
	DST=$SITEHOME/etc/apache/conf.d/nrdp.conf
	if [[ ! -f $DST ]] || ! diff -q $TMPF $DST 2>/dev/null ; then
		cp $TMPF1 $DST
		chown ${site}.${site} $DST
	fi
done
