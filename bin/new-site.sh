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

Create a new OMD naemon site, configure NSCA and LiveStatus.

Options:
--------
    -h
	    Show this help.
"
    exit $xval
}

SHORTHOST=$(hostname -s)
case "$SHORTHOST" in
	*-nagios.fsautomation.com ) SITENAME=$(echo $SHORTHOST | sed -e 's/-.*//' ;;
	* )
		echo "This hostname is not of the {cust}-nagios.fsautomation.com format"
		echo "Rename the host properly, then run this script again."
		exit 1
		;;
esac

echo "Installing new site: $SITENAME"
read -p "Is this OK? > " ANS
case "$ANS" in
	y* | Y* ) : ;;
	* ) echo "Exiting"; exit 1 ;;
esac

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

# Check to see if the standard SSL site is configured.
SSLKEYFILE=/etc/pki/wildcard.fsautomation.com/private/wildcard.fsautomation.com.key
SSLCRTFILE=/etc/pki/wildcard.fsautomation.com/certs/wildcard-combined.crt
SSLCONFFILE=/etc/httpd/conf.d/ssl.conf
if ! grep -q "SSLCertificateFile $SSLCRTFILE" $SSLCONFFILE || \
	! grep -q "SSLCertificateKeyFile $SSLKEYFILE" $SSLCONFFILE ; then
	out "Setting SSL cert to wildcard cert"
	if cp $SSLCONFFILE $SSLCONFFILE.$TIMESTAMP ; then
		sed -i -e "s,^SSLCertificateFile .*,SSLCertificateFile $SSLCRTFILE," \
			-e "s,^SSLCertificateKeyFile .*,SSLCertificateKeyFile $SSLKeyFILE," \
			$SSLCONFFILE
	fi
	# If the wildcard certs are not there, copy the current ones.
	[[ -f $SSLKEYFILE ]] || cp /etc/pki/tls/private/localhost.key $SSLKEYFILE
	[[ -f $SSLCRTFILE ]] || cp /etc/pki/tls/certs/localhost.crt $SSLCRTFILE
fi

date >> $LOGFILE
section "Working on $SITENAME ..." | tee -a $LOGFILE
	
# See if it exists
# We exit 1 from awk if we DO find it.
if ! omd sites | awk '$1 == "'$SITENAME'" { exit(1); }' ; then
	out "Site exists."
	exit 1
fi
omd create $SITENAME >> $TMPF1 2>&1
if [[ $? -ne 0 ]]; then
	cat $TMPF1
	exit 1
fi
cat $TMPF1 | tee -a $LOGFILE
SITE_HOME=$(getent passwd $SITENAME | awk -F: '{ print $6 }')

# For now, NSCA is good enough.
run_omd $SITENAME config set NSCA on
MYPORT=5667
while grep -w -q $MYPORT $TMP_NSCA_PORTS ; do
	MYPORT=$(( MYPORT + 1 ))
done
echo "$MYPORT" >> $TMP_NSCA_PORTS
out "Setting NSCA port to $MYPORT" | tee -a $LOGFILE
run_omd $SITENAME config set NSCA_TCP_PORT $MYPORT

out "Adding port to firewall"
firewall-cmd --permanent --add-port=$MYPORT/tcp

# Add live status
run_omd $SITENAME config set LIVESTATUS_TCP on
MYPORT=6557
while grep -w -q $MYPORT $TMP_LIVE_PORTS ; do
	MYPORT=$(( MYPORT + 1 ))
done
echo "$MYPORT" >> $TMP_LIVE_PORTS
out "Setting Livestatus port to $MYPORT" | tee -a $LOGFILE
run_omd $SITENAME config set LIVESTATUS_TCP_PORT $MYPORT

out "Adding port to firewall"
firewall-cmd --permanent --add-port=$MYPORT/tcp
firewall-cmd --reload

DEFSITECONF=/opt/httpd/conf.d/omd-default.site.conf
if [[ ! -f $DEFSITECONF ]]; then
	out "Setting '$SITENAME' as the default site for this server."
	echo "RedirectMatch ^/$ /${SITENAME}/" > $DEFSITECONF
	systemctl restart httpd
fi


out "Update the omdadmin web password"
htpasswd $SITE_HOME/etc/htpasswd omdadmin

out "Generating SSH key for git pulls"
if [[ ! -d $SITE_HOME/.ssh ]] ; then
	mkdir $SITE_HOME/.ssh
fi
ssh-keygen -t rsa -N '' -q -f $SITE_HOME/.ssh/id_rsa
chown -R $SITENAME.$SITENAME $SITE_HOME/.ssh
chmod -R go-rwx $SITE_HOME/.ssh

out "You will need to paste this as the deploy key for the"
out "nagios-config repo:"
cat $SITE_HOME/.ssh/id_rsa.pub
read -p "Press ENTER after this is done to continue> " ANS

# Create a script to checkout the nagios-config repo
out "Checking out the nagios-config repo"
cat > $TMPF1 <<EOF
#!/bin/bash
cd
cd local || exit 1
git clone git@github.com:foresightautomation/nagios-config.git
EOF
out Finished with $SITENAME

section "Finished.  Logged to $LOGFILE"
