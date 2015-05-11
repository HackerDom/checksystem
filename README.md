# checksystem [![Build Status](https://travis-ci.org/HackerDom/checksystem.svg?branch=master)](https://travis-ci.org/HackerDom/checksystem)
Checksystem for attack-defense CTF

# install
```bash
root# apt-get install postgresql-9.4 libssl-dev libpq-dev cpanminus
root# cpanm --installdeps .
```

# configure
```bash
psql$ createuser -P cs
psql$ createdb -O cs cs
```

# run
```bash
ctf$ $EDITOR c_s.conf
ctf$ script/cs ensure_db
ctf$ script/cs manager
ctf$ script/cs flags
ctf$ script/cs minion worker -j 48
ctf$ hypnotoad script/cs
```
