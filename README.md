# nagios-build

This repo has a couple of scripts for performing the setup of a monitoring server based on the Lab Consol ODM package.

Grab the files in this repo:

```bash
wget -O - https://github.com/foresightautomation/nagios-build/archive/master.tar.gz | tar xvzf -
```

```bash
cd nagios-build-master
./bin/00-prep.sh
```

This will download and install the needed repos and packages.

```bash
./bin/new-site.sh
```

Creates a new site, enables NCPA, LiveStatus, and NRDP, and creates an ssh
key that can be used to deploy the nagios-config repo.
