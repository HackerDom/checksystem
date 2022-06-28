# Checksystem

It's a scalable competition platform for attack-defense [CTF](https://en.wikipedia.org/wiki/Capture_the_flag_(cybersecurity)).

It's written in [Perl](https://www.perl.org/) with [Mojolicious](https://www.mojolicious.org/) framework.

## Architecture

- `cs-manager`: a component that is responsible for the beginning and ending of the game, for managing breaks, for generating rounds. After the start of the round it puts tasks in the queue for launching checkers and also puts the task in the queue for calculating the scoreboard for the past rounds.

- `cs-watcher`: an optional component which periodically (several times per round) checks the availability of the TCP port for each service and team and skips launching the checkers if the port is not available.

- `postgres`: the [database](https://www.postgresql.org/) which used to store all the data required for the checksystem. It's also used as a backend for the [Minion](https://docs.mojolicious.org/Minion) job queue.

- `cs-worker`: the minion workers which runs the checkers for teams and services.

- `cs-web`: the [hypnotoad](https://docs.mojolicious.org/hypnotoad) which serves checksystem's web components: scoreboars, API, flags.

## Useful URLs

- `/board`: a built-in scoreboard with simple html table with teams, services and scores.
- `/admin`: an admin page for the game which allows to view checker's logs.
- `/admin/info`: an admin page with useful game statistics.
- `/admin/minion`: an admin page with jobs statistics.
- `/ctftime/scoreboard.json`: a scoreboard in [CTFtime](https://ctftime.org/) format.

## HTTP API

### For scoreboard

### For teams

## API between checkers and checksystem

Checker is an executable file that get input from the checksystem via args and `STDIN` and return output via exit code and `STDOUT/STDERR`.

Checksystem runs checkers with that format: `/path/to/checker mode host id flag`

### Modes

#### INFO

Cheker must return `101` exit code and print to `STDOUT` lines with `key: value` format. Supported keys:

- `public_flag_description`: description of flag in the service for teams.
- `vulns`: number of vulns in the service, must be set to `1`.

##### CHECK

The checker must check the general functionality of the service at `host`.

##### PUT

The checker must put the `flag` to the service at `host` by `id`. If exit code is 101 then checker should print to `STDOUT` a `JSON object` with `public_flag_id` field wich will be accessible to the teams. You can add any additional fields to the object. This `JSON object` will be passed to the `GET` mode in the future.

##### GET

The checker must try to get `flag` from the service at `host` by `id`.
### Exit codes

- `101` OK.
- `102` CORRUPT: The service works fine, but there is no requested flag (only in `get` mode)
- `103` MUMBLE: The service works incorrect
- `104` DOWN: The service doesn't work.
- `110` CHECKER ERROR: Internal error of checker.
