# checksystem

It's a scalable competition platform for attack-defense [CTF](https://en.wikipedia.org/wiki/Capture_the_flag_(cybersecurity)).

It's written in [Perl](https://www.perl.org/) with [Mojolicious](https://www.mojolicious.org/) framework;

## Architecture

- `cs-manager`: the component that is responsible for the beginning and ending of the game, for managing breaks, for generating rounds. After the start of the round it puts tasks in the queue for launching checkers and also puts the task in the queue for calculating the scoreboard for the past rounds.

- `cs-watcher`: an optional component which periodically (several times per round) checks the availability of the TCP port for each service and team and skips launching the checkers if the port is not available.

- `postgres`: the [database](https://www.postgresql.org/) which used to store all the data required for the checksystem. It's also used as a backend for the [Minion](https://docs.mojolicious.org/Minion) job queue.

- `cs-worker`: the minion workers which runs the checkers for teams and services.

- `cs-web`: the [hypnotoad](https://docs.mojolicious.org/hypnotoad) which serves checksystem's web components: scoreboars, API, flags.

## Useful URLs

## API
