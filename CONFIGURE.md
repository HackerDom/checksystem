# Intro

Config file for the checksystem is a just [Perl file](https://docs.mojolicious.org/Mojolicious/Plugin/Config) which returning a hash object. You can found example at [cs.conf.example](cs.conf.example).

# Available options:

- `hypnotoad`: this hash describe the settings about hypnotoad web server. You can read details in the [official documentation](https://docs.mojolicious.org/Mojo/Server/Hypnotoad).
- `postgres_uri`: [connection string](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING) for postgres database. You can override this option by `POSTGRES_URI` environmental variable.
- `base_url`: base `url` which used to create a right redirect urls. Useful if you publish scoreboard in the Internet.
- `cs.time`: list of the game's periods. You must specify the time in the same time zone as the server that runs the checksystem. If you use [docker deploy](deploy/README.md) then specify time in `UTC` time zone. If you don't specify `cs.time` option, then the game will be endless, which can be convenient for trainings.
- `cs.round_length`: length of round in seconds. Default value is `60`
- `cs.flag_life_time`: time of flag's life in rounds. Doesn't persist after any breaks in the game. Default value is `15`.
- `cs.flags_secret`: secret key for HMAC in flag's data.
- `cs.checkers.hostname`: an optional callback function to detect an address of vuln's service which passed to the checkers.
- `cs.ctf_name`: a name of the CTF, displayed in the scoreboard. Default vaule is `CTF`.
- `cs.admin_auth`: a basic auth creadentials of admin page (which can be accessed by `/admin` route).
- `cs.scoring`: this hash object describe the settings about the [scoring](https://docs.google.com/document/d/1uU9f38UpxdsMeuAsM5TAnp_i4T-DhM-Ur9JOxUeTc8M/preview#heading=h.xdi2syovqugn).
- `teams`: a list of the [teams](#teams).
- `services`: a list of the [services](#services).

## teams

- `name`:
- `network`:
- `host`:
- `logo`:
- `token`:
- `tags`:

## services

Available attributes of the service's hash:

- `name`: a name of the service.
- `path`: a path (absolute or relative to the root catalog of this project) to the service's main executable file.
- `timeout`: an amount in seconds of checker's timeout. The service will have the status `down` in the current round if there is a timeout. An actual timeout for current stage (`check`, `put`, `get`) in the round is calculated as miniumum of the `timeout` from config and time prior to the start of the next round.
- `tcp_port`: a main tcp port of the service.
