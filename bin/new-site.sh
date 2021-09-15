#!/bin/bash
#
# Make this idempotent so as new features are added, this script
# can be run multiple times.
TOPDIR=$(realpath $(dirname $0)/..)
. $TOPDIR/etc/omd-build.env || exit 1
STARTDIR=$(pwd)
ONTTY=0
tty -s && ONTTY=1

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

    -Q
        Query to overwrite/re-install pieces that are already installed.
"
    exit $xval
}

# Prompt the user to re-install if they have DO_QUERY set.
# do_reinstall "component"
function do_reinstall {
	typeset _component="$@"
	typeset _ans
	[[ $DO_QUERY -eq 1 ]] || return 1
	echo "$_component already installed/configured."
	read -p "Re-install? [y/N]> " _ans
	case "$_ans" in
		y* | Y* ) return 0 ;;
	esac
	return 1
}

SITE_SPECIFIED=0
DO_QUERY=0
while getopts Qhs: c ; do
	case "$c" in
		Q ) [[ $ONTTY -eq 1 ]] && DO_QUERY=1 ;;
		h ) usage 0 ;;
		s ) export OMD_SITE="$OPTARG" ; SITE_SPECIFIED=1 ;;
		-- ) break ;;
		* ) usage 2 unknown option ;;
	esac
done
shift $(( OPTIND - 1 ))

#
# This is very simple check that hopefully allows us to run this via
# an automatic script.
if [[ -z "$OMD_SITE" ]]; then
	LONGHOST=$(hostname)
	case "$LONGHOST" in
		*-nagios.fsautomation.com ) export OMD_SITE=$(basename $LONGHOST -nagios.fsautomation.com) ;;
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

#
# Initial configuration
function initial_config() {
	if [[ $SITE_EXISTS -eq 0 ]]; then
		echo "Installing new site: $OMD_SITE"
		if [[ $ONTTY -eq 1 && $SITE_SPECIFIED -eq 0 ]]; then
			read -p "Is this OK? > " ANS
			case "$ANS" in
				y* | Y* ) : ;;
				* ) echo "Exiting"; exit 1 ;;
			esac
		fi
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
		export OMD_ROOT=$(getent passwd $OMD_SITE | awk -F: '{ print $6 }')

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
EOF
		chmod 755 $TMPF1
		su $OMD_SITE -c "/bin/bash $TMPF1"
		chmod 600 $TMPF1
	fi
}
initial_config
# Grab the OMD_ROOT
[[ -z "$OMD_ROOT" ]] && OMD_ROOT=$(getent passwd $OMD_SITE | awk -F: '{ print $6 }')
function version_gt() {
	test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1";
}

##
## NRDP
##
## NOTE: as of nrdp-2.0.4, the tar file included in the repo has been patched
##       to fix the file format of the checkresults file so that it works with
##       naemon.
function nrdp_config() {
	typeset _f1
	typeset CUR_VERSION=""
	NRDP_VERSION=2.0.4
	NRDP_TOP=$OMD_ROOT/local/share/nrdp

	out "Checking for NRDP $NRDP_VERSION" | tee -a $LOGFILE

	# Find the current version installed.
	# If the cur version is older than this script's version, back it up.
	# If the cur version is newer than this script's version, return.
	# If the cur version is the same as this script's version, query the user.
	_F1="$NRDP_TOP/server/includes/constants.inc.php"
	if [[ -f "$_F1" ]]; then
		CUR_VERSION=$(egrep '^define\("PRODUCT_VERSION",' "$_F1" | \
			sed -e 's/.*"\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/')
		if [[ -n "$CUR_VERSION" ]]; then
			# If the new version is newer than the previous version, 
			# then back it up.
			if version_gt "$NRDP_VERSION" "$CUR_VERSION" ; then
				echo "NRDP $CUR_VERSION installed.  Backing up to $NRDP_TOP.$TIMESTAMP"
				
				OLD_NRDP_TOKEN=$($OMD_ROOT/local/bin/get-nrdp-password 2>/dev/null)
				/bin/mv "$NRDP_TOP" "$NRDP_TOP.$TIMESTAMP"
			elif version_gt "$CUR_VERSION" "$NRDP_VERSION" ; then
				echo "NRDP $CUR_VERSION installed and is newer.  Skipping."
				return 1
			else
				if do_reinstall NRDP ; then
					/bin/mv "$NRDP_TOP" "$NRDP_TOP.$TIMESTAMP"
				else
					out "NRDP $NRDP_VERSION installed.  Skipping." | tee -a $LOGFILE
					return 1
				fi
			fi
		fi
	fi
	if [[ -d "$NRDP_TOP" ]] && do_reinstall "NRDP (unknown version)" ; then
		OLD_NRDP_TOKEN=$($OMD_ROOT/local/bin/get-nrdp-password 2>/dev/null)
		/bin/mv "$NRDP_TOP" "$NRDP_TOP.$TIMESTAMP"
	fi

	# If we're here and we have a directory, then just return.
	[[ -d "$NRDP_TOP" ]] && return 1

	out "Installing NRDP $NRDP_VERSION" | tee -a $LOGFILE
	su $OMD_SITE -c "mkdir -p '$NRDP_TOP'" || exit 1
	tar --strip-components=1 -C "$NRDP_TOP" -xzf \
		$TOPDIR/src/nrdp-$NRDP_VERSION.tar.gz

	chown -R $OMD_SITE.$OMD_SITE "$NRDP_TOP"

	# because we're running in the global apache as 'apache' instead
	# of the site apache as the site user, we need to make sure that
	# the checkresults directory has the setgid bit set to allow
	# the site user to read and delete the files placed by the
	# apache user.
	out "  updating permissions on checkresults dir"
	chmod g+s $OMD_ROOT/tmp/naemon/checkresults
	
	# Copy the nrdp.conf file
	out "  installing nrdp.conf apache config" | tee -a $LOGFILE
	sed -e "s|\${OMD_SITE}|$OMD_SITE|g" \
		-e "s|\${OMD_ROOT}|$OMD_ROOT|g" \
		"$TOPDIR"/src/nrdp.conf  > $TMPF1
	copy_site_file $TMPF1 "$OMD_ROOT/etc/apache/system.d/nrdp.conf"
	
	out "  updating nrdp config.inc.php ..." | tee -a $LOGFILE
	DST=$NRDP_TOP/server/config.inc.php

	out "  setting token ..." | tee -a $LOGFILE
	if [[ -n "$OLD_NRDP_TOKEN" ]];  then
		$OMD_ROOT/local/bin/get-nrdp-password --set --password "$OLD_NRDP_TOKEN"
	else
		$OMD_ROOT/local/bin/get-nrdp-password --set
	fi
	
	# We're going to:
	#   - set the command group
	#   - set the checkresults dir
	#   - set the command file
	#   - change log file
	sed -i.$TIMESTAMP \
		-e "s/nagcmd/$OMD_SITE/" \
		-e "s|/usr/local/nagios/var/rw/nagios.cmd|$OMD_ROOT/tmp/run/naemon.cmd|" \
		-e "s|/usr/local/nagios/var/spool/checkresults|$OMD_ROOT/tmp/naemon/checkresults|" \
		-e "s|/usr/local/nrdp/server/debug.log|$OMD_ROOT/var/log/nrdp.debug.log|" \
		$DST
	
	out "  restarting httpd" | tee -a $LOGFILE
	systemctl restart httpd
}
nrdp_config
##
## NSCP
##
function nscp_config() {
	typeset _f1
	NSCP_TOP=$OMD_ROOT/local/share/nscp

	section "Checking NSCP ..."

	if [[ ! -d "$NSCP_TOP" ]]; then
		out "  installing NSCP directory ... " | tee -a $LOGFILE
		su $OMD_SITE -c "mkdir -p '$NSCP_TOP'"
		chown -R $OMD_SITE.$OMD_SITE "$NSCP_TOP"
	fi

	# Copy the Apache nscp.conf file
	_f1="$OMD_ROOT/etc/apache/system.d/nscp.conf"
	if [[ ! -f "$_f1" ]]; then
		out "  installing nscp.conf apache config" | tee -a $LOGFILE
		sed -e "s|\${OMD_SITE}|$OMD_SITE|g" \
			-e "s|\${NSCP_TOP}|$NSCP_TOP|g" \
			"$TOPDIR"/src/nscp-apache.conf  > $TMPF1
		copy_site_file $TMPF1 "$OMD_ROOT/etc/apache/system.d/nscp.conf"
	
		out "  reloading httpd" | tee -a $LOGFILE
		systemctl reload httpd
	fi
}
nscp_config

#
	
section "Finished."| tee -a $LOGFILE
echo "Logged to $LOGFILE"
echo ""
echo "To complete the site setup, run:"
echo ""
echo "    omd su $OMD_SITE"
echo "    omd start"
echo "    ./local/nagios-config/bin/run-deploy.pl"
echo "    hash -r"
echo "    fsa-init-nagios-server"
