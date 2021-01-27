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
	echo "usage: OPTIONS [sitename]

Create a new OMD naemon site, configure NSCA, LiveStatus, and NRPD.

Options:
--------
    -h
	    Show this help.

    -s sitename
        Use the site name specified.  Otherwise, it's determined based
        on the hostname.
"
    exit $xval
}

while getopts hs: c ; do
	case "$c" in
		h ) usage 0 ;;
		s ) OMD_SITE="$OPTARG" ;;
		-- ) break ;;
		* ) usage 2 unknown option ;;
	esac
done
shift $(( OPTIND - 1 ))

if [[ -z "$OMD_SITE" ]]; then
	LONGHOST=$(hostname)
	case "$LONGHOST" in
		*-nagios.fsautomation.com ) OMD_SITE=$(basename $LONGHOST -nagios.fsautomation.com) ;;
		* )
			echo "This hostname is not of the {cust}-nagios.fsautomation.com format"
			echo "Rename the host properly, then run this script again, or specify"
			echo "the '-s' flag to override the site name."
			exit 1
			;;
	esac
fi

# See if it exists
SITE_EXISTS=0
# We exit 1 from awk if we DO find it.
if ! omd sites | awk '$1 == "'$OMD_SITE'" { exit(1); }' ; then
	out "Site exists.  Skipping initial setup."
	SITE_EXISTS=1
fi

TMPF1=
TMP_NSCA_PORTS=
TMP_LIVE_PORTS=
cleanup() {
	/bin/rm -f $TMPF1 $TMP_NSCA_PORTS $TMP_LIVE_PORTS
}
trap cleanup 0
TMPF1=$(mktemp /tmp/XXXXXXXX)

# Run an osm command for the site
# run_osm site command ...
run_omd() {
    typeset _site=$1
	shift
	echo "omd $@" | omd su $_site | egrep -v '^Last login'
}

if [[ $SITE_EXISTS -eq 0 ]]; then
	echo "Installing new site: $OMD_SITE"
	read -p "Is this OK? > " ANS
	case "$ANS" in
		y* | Y* ) : ;;
		* ) echo "Exiting"; exit 1 ;;
	esac
	TMP_NSCA_PORTS=$(mktemp /tmp/XXXXXXXX)
	TMP_LIVE_PORTS=$(mktemp /tmp/XXXXXXXX)
	
	
	section "Working on $OMD_SITE ..." | tee -a $LOGFILE
	
	# Grab a list of all of the NSCA and LIVESTATUS ports.
	for i in $(omd sites | awk '$NR > 1 { print $1 }'); do
		run_omd $i "config show NSCA_TCP_PORT" 2>/dev/null >> $TMP_NSCA_PORTS
		run_omd $i "config show LIVESTATUS_TCP_PORT" 2>/dev/null >> $TMP_LIVE_PORTS
	done
	sed -i -e '/Last login/d' -e '/^$/d' $TMP_NSCA_PORTS
	sed -i -e '/Last login/d' -e '/^$/d' $TMP_LIVE_PORTS
	
	# Check to see if the standard SSL site is configured.
	SSLKEYFILE=/etc/pki/wildcard.fsautomation.com/private/wildcard.fsautomation.com.key
	SSLCRTFILE=/etc/pki/wildcard.fsautomation.com/certs/wildcard-combined.crt
	SSLCONFFILE=/etc/httpd/conf.d/ssl.conf
	if ! grep -q "SSLCertificateFile $SSLCRTFILE" $SSLCONFFILE || \
		! grep -q "SSLCertificateKeyFile $SSLKEYFILE" $SSLCONFFILE ; then
		out "Setting global SSL cert to wildcard cert"
		if cp $SSLCONFFILE $SSLCONFFILE.$TIMESTAMP ; then
			sed -i -e "s,^SSLCertificateFile .*,SSLCertificateFile $SSLCRTFILE," \
				-e "s,^SSLCertificateKeyFile .*,SSLCertificateKeyFile $SSLKEYFILE," \
				$SSLCONFFILE
		fi
		# If the wildcard certs are not there, copy the current ones.
		[[ -f $SSLKEYFILE ]] || cp /etc/pki/tls/private/localhost.key $SSLKEYFILE
		[[ -f $SSLCRTFILE ]] || cp /etc/pki/tls/certs/localhost.crt $SSLCRTFILE
	fi
	
	date >> $LOGFILE
	
	omd create $OMD_SITE 2>&1 | tee -a $LOGFILE
	if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
		exit 1
	fi
	OMD_ROOT=$(getent passwd $OMD_SITE | awk -F: '{ print $6 }')
	
	# Turn on NSCA
	run_omd $OMD_SITE config set NSCA on
	MYPORT=5667
	while grep -w -q $MYPORT $TMP_NSCA_PORTS ; do
		MYPORT=$(( MYPORT + 1 ))
	done
	echo "$MYPORT" >> $TMP_NSCA_PORTS
	out "Setting NSCA port to $MYPORT" | tee -a $LOGFILE
	run_omd $OMD_SITE config set NSCA_TCP_PORT $MYPORT
	
	if [[ "$OS_ID" != "amzn" ]]; then
		out "Adding port to firewall"
		firewall-cmd --permanent --add-port=$MYPORT/tcp
		firewall-cmd --reload
	fi
	
	# Add live status
	run_omd $OMD_SITE config set LIVESTATUS_TCP on
	MYPORT=6557
	while grep -w -q $MYPORT $TMP_LIVE_PORTS ; do
		MYPORT=$(( MYPORT + 1 ))
	done
	echo "$MYPORT" >> $TMP_LIVE_PORTS
	out "Setting Livestatus port to $MYPORT" | tee -a $LOGFILE
	run_omd $OMD_SITE config set LIVESTATUS_TCP_PORT $MYPORT
	
	if [[ "$OS_ID" != "amzn" ]]; then
		out "Adding port to firewall"
		firewall-cmd --permanent --add-port=$MYPORT/tcp
		firewall-cmd --reload
	fi
	
	DEFSITECONF=/etc/httpd/conf.d/omd-default.site.conf
	if [[ ! -f $DEFSITECONF ]]; then
		out "Setting '$OMD_SITE' as the default site for this server."
		echo "RedirectMatch ^/$ /${OMD_SITE}/" > $DEFSITECONF
		systemctl restart httpd
	fi
	
	
	out "Update the omdadmin web password"
	htpasswd $OMD_ROOT/etc/htpasswd omdadmin
	
	out "Generating SSH key for git pulls"
	if [[ ! -d $OMD_ROOT/.ssh ]] ; then
		mkdir $OMD_ROOT/.ssh
	fi
	ssh-keygen -t rsa -N '' -q -f $OMD_ROOT/.ssh/id_rsa
	chown -R $OMD_SITE.$OMD_SITE $OMD_ROOT/.ssh
	chmod -R go-rwx $OMD_ROOT/.ssh
	
	echo ""
	out "You will need to paste this as the deploy key for the"
	out "nagios-config repo:"
	echo ""
	cat $OMD_ROOT/.ssh/id_rsa.pub
	echo ""
	read -p "Press ENTER after this is done to continue> " ANS
	
	out "Checking out the nagios-config repo"
	cat > $TMPF1<<EOF
#!/bin/bash
cd ~/local
ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
git clone git@github.com:foresightautomation/nagios-config.git
cd nagios-config
git checkout $OMD_SITE
EOF
	chmod 755 $TMPF1
	su $OMD_SITE -c "/bin/bash $TMPF1"
	chmod 600 $TMPF1
fi
	
NRDP_VERSION=2.0.3
NRDP_TOP=$OMD_ROOT/local/share/nrdp
if [[ ! -d "$NRDP_TOP" ]]; then
	out "Installing NRDP" | tee -a $LOGFILE
	[[ -d "$NRDP_TOPDIR" ]] || su $OMD_SITE -c "mkdir -p '$NRDP_TOP'" || exit 1
	tar --strip-components=1 -C "$NRDP_TOP" -xzf $TOPDIR/src/nrdp-$NRDP_VERSION.tar.gz
	chown -R $OMD_SITE.$OMD_SITE "$NRDP_TOP"
	# NRDP is just an http alias, so no port needed.

	# Copy the nrdp.conf file
	out "  installing nrdp.conf apache config" | tee -a $LOGFILE
	sed -e "s|\${OMD_SITE}|$OMD_SITE|g" \
		-e "s|\${OMD_ROOT}|$OMD_ROOT|g" \
		"$TOPDIR"/src/nrdp.conf  > $TMPF1
	copy_site_file $TMPF1 "$OMD_ROOT/etc/apache/system.d/nrdp.conf"
	out "  restarting httpd" | tee -a $LOGFILE
	systemctl restart httpd

	out "  creating NRDP secret token ..." | tee -a $LOGFILE
	# Generate some entropy
	(find / -xdev -type f -print 2>/dev/null | xargs cat >/dev/null 2>&1&)&
	ENTROPYPID=$!
	TOKEN=$(apg -m 12 -n 1 -M NCL)
	[[ -d /proc/$ENTROPYPID ]] && kill -TERM $ENTROPYPID
	out "  updating nrdp config.inc.php ..." | tee -a $LOGFILE
	DST=$NRDP_TOP/server/config.inc.php

	# We're going to:
	#   - append a new token after the sample token
	#   - set the command group
	#   - set the checkresults dir
	#   - set the command file
	#   - change log file
	sed -i.$TIMESTAMP \
        -e "/90dfs7jwn3/a  \"$TOKEN\"," \
		-e "s/nagcmd/$OMD_SITE/" \
        -e "s|/usr/local/nagios/var/rw/nagios.cmd|$OMD_ROOT/tmp/run/naemon.cmd|" \
        -e "s|/usr/local/nagios/var/spool/checkresults|$OMD_ROOT/tmp/naemon/checkresults|" \
        -e "s|/usr/local/nrdp/server/debug.log|$OMD_ROOT/var/log/nrdp.debug.log|" \
        $DST
fi
	
section "Finished."| tee -a $LOGFILE
echo "Logged to $LOGFILE"
echo ""
echo "To complete the site setup, run 'omd su $OMD_SITE', then run:"
echo "    ./local/nagios-config/bin/run-deploy.pl --deploy-full"
echo "    fsa-init-nagios-server"
