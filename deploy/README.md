For hosting a small CTF competition you can use a simple way to run the checksystem via `docker compose` on a single node.

If you want to have a more scalable and performance deploy you can look at the [ansible](../ansible) scripts.

_How to understand which node's configuration to use?_

It depends on the quality of the checkers and their dependencies. In our experience the good checkers use minimum amount of CPU and RAM and utilize only network I/O.

We believe that the CTF competition for about **30 teams** and **10 services** can be deployed on single node with 32-48 dedicated modern CPU and 64 GB of RAM and 50 GB of SSD/NVMe local storage. Such configuration costs about 1.5$/hour in cloud providers.


You need a node with a fresh GNU/Linux (for example Debian or Ubuntu) and a fresh version of [docker engine](https://docs.docker.com/engine/install/) and [docker compose](https://docs.docker.com/compose/install/).

Copy the [docker-compose.yml](docker-compose.yml) and example of [Dockerfile](Dockerfile) files on your node and create files `cs.conf` (by looking at the [example](../cs.conf.example) in the repo and at the [CONFIGURE.md](../CONFIGURE.md)) and `.env` like this:

```bash
POSTGRES_USER=postgres
POSTGRES_PASSWORD=Secr3t
POSTGRES_DB=cs
POSTGRES_URI=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@pg/${POSTGRES_DB}
MOJO_LISTEN=http://0.0.0.0:8080
```

Don't forget about the checkers for the game. You must extend [Dockerfile](Dockerfile) with you CTF's specific checkers and their denendencies. Also don't forget to add execute permission (`chmod +x`) to [main files](../CONFIGURE.md#services) of the checkers.

And then start the checksystem via `docker compose up -d` and use web interface at `http://localhost`. By default, this deployment uses a [modern scoreboard](https://github.com/HackerDom/ctf-scoreboard-client) and you can still use original scoreboard at `http://localhost/board`.
