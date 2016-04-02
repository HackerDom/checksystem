# checksystem [![Build Status](https://travis-ci.org/HackerDom/checksystem.svg?branch=master)](https://travis-ci.org/HackerDom/checksystem)
Checksystem for attack-defense CTF

# install
```bash
root# apt-get install postgresql-9.5 libssl-dev libpq-dev cpanminus
root# cpanm --installdeps .
```

# configure
```bash
psql$ createuser -P cs
psql$ createdb -O cs cs
ctf$ cp cs.conf.example c_s.conf
ctf$ $EDITOR c_s.conf
```

# run
```bash
ctf$ MOJO_CONFIG=c_s.conf script/cs ensure_db
ctf$ MOJO_CONFIG=c_s.conf script/cs manager
ctf$ MOJO_CONFIG=c_s.conf script/cs flags
ctf$ MOJO_CONFIG=c_s.conf script/cs minion worker -j 3
ctf$ MOJO_CONFIG=c_s.conf script/cs minion worker -q checker -j 48
ctf$ MOJO_CONFIG=c_s.conf hypnotoad script/cs
```
