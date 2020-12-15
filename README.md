# nagios-build

This repo has a couple of scripts for performing the setup of a
monitoring server based on the Lab Consol ODM package.

Grab the files in this repo, then run:

```bash
./bin/00-prep.sh
```

This will download and install the needed repos and packages.

```bash
./bin/new-site.sh {sitename}
```

Creates a new site, enables NCPA and LiveStatus, and creates an ssh
key that can be used to deploy the nagios-config repo.
