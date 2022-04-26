-- 1 up (init)
create table teams (
  id      serial primary key,
  name    text not null unique,
  network cidr not null,
  host    text not null,
  token   text unique
);

create table services (
  id                      serial primary key,
  name                    text not null unique,
  vulns                   text not null,
  ts_start                timestamptz,
  ts_end                  timestamptz,
  public_flag_description text
);

create table vulns (
  id         serial primary key,
  service_id integer not null references services(id),
  n          smallint not null check (n > 0),
  unique (service_id, n)
);

create table rounds (
  n  integer primary key,
  ts timestamptz not null default now()
);

create type service_phase as enum ('NOT_RELEASED', 'HEATING', 'COOLING_DOWN', 'DYING', 'REMOVED');
create table service_activity (
  id               serial primary key,
  ts               timestamptz not null default now(),
  round            integer not null references rounds(n),
  service_id       integer not null references services(id),
  active           boolean not null,
  flag_base_amount float8 not null default 0,
  phase            service_phase not null,
  unique (round, service_id)
);
create index on service_activity (service_id, phase);

create table flags (
  data       text primary key,
  id         text not null,
  public_id  text,
  round      integer not null references rounds(n),
  ts         timestamptz not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  vuln_id    integer not null references vulns(id),
  ack        boolean not null default false,
  expired    boolean not null default false,
  unique (round, team_id, service_id)
);
create index on flags (expired, service_id);

create table stolen_flags (
  data    text not null references flags(data),
  ts      timestamptz not null default now(),
  round   integer not null references rounds(n),
  team_id integer not null references teams(id),
  amount  float8 not null,
  unique (data, team_id)
);
create index on stolen_flags (data, team_id);

create table runs (
  round      integer not null references rounds(n),
  ts         timestamptz not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  vuln_id    integer not null references vulns(id),
  status     integer not null,
  result     jsonb,
  stdout     text,
  unique (round, team_id, service_id)
);
create index on runs (round);

create table sla (
  round      integer not null references rounds(n),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  successed  integer not null,
  failed     integer not null,
  unique (round, team_id, service_id)
);
create index on sla (round);

create table flag_points (
  round      integer not null references rounds(n),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  amount     float8 not null,
  unique (round, team_id, service_id)
);
create index on flag_points (round);

create table bots (
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  sla        float8 not null,
  attack     float8 not null,
  defense    float8 not null
);

create table monitor (
  round      integer not null references rounds(n),
  ts         timestamptz not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  status     boolean not null,
  error      text
);

create table scores (
  round      integer not null references rounds(n),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  sla        float8 not null,
  fp         float8 not null,
  flags      integer not null,
  sflags     integer not null,
  status     integer not null,
  stdout     text,
  unique (round, team_id, service_id)
);
create index on scores (round);

create table scoreboard (
  round    integer not null references rounds(n),
  team_id  integer not null references teams(id),
  score    numeric not null,
  n        smallint not null,
  services jsonb not null,
  unique (round, team_id)
);
create index on scoreboard (round);
create index on scoreboard (team_id);

create function accept_flag(team_id integer, flag_data text) returns record as $$
<<my>>
declare
  flag   flags%rowtype;
  round  rounds.n%type;
  amount stolen_flags.amount%type;

  attacker_pos smallint;
  victim_pos   smallint;
  amount_max   float8;
  teams_count  smallint;

  service_active boolean;
begin
  select * from flags where data = flag_data into flag;

  if not found then return row(false, 'Denied: no such flag'); end if;
  if team_id = flag.team_id then return row(false, 'Denied: invalid or own flag'); end if;
  if flag.expired then return row(false, 'Denied: flag is too old'); end if;

  select now() between coalesce(ts_start, '-infinity') and coalesce(ts_end, 'infinity')
  from services where id = flag.service_id into service_active;
  if not service_active then return row(false, 'Denied: service inactive'); end if;

  perform * from stolen_flags as sf where sf.data = flag_data and sf.team_id = accept_flag.team_id;
  if found then return row(false, 'Denied: you already submitted this flag'); end if;

  select max(s.round) into round from scoreboard as s;
  select n from scoreboard as s where s.round = my.round - 1 and s.team_id = accept_flag.team_id into attacker_pos;
  select n from scoreboard as s where s.round = my.round - 1 and s.team_id = flag.team_id into victim_pos;

  select count(*) from teams into teams_count;
  select flag_base_amount into amount_max
  from service_activity as sa
  where sa.service_id = flag.service_id and sa.round = flag.round;

  amount = case when attacker_pos >= victim_pos
    then amount_max
    else amount_max ^ (1 - ((victim_pos - attacker_pos) / (teams_count - 1)))
  end;

  select max(n) into round from rounds;
  insert into stolen_flags (data, team_id, round, amount)
    values (flag_data, team_id, round, amount) on conflict do nothing;
  if not found then return row(false, 'Denied: you already submitted this flag'); end if;

  return row(true, null, round, flag.team_id, flag.service_id, amount);
end;
$$ language plpgsql;
-- 1 down
drop function if exists accept_flag(integer, text);
drop table if exists rounds, monitor, scores, teams, vulns, services, service_activity, flags,
  stolen_flags, runs, sla, flag_points, scoreboard, bots;
drop type if exists service_phase;
