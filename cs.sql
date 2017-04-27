-- 1 up (init)
create table teams (
  id      serial primary key,
  name    text not null unique,
  network cidr not null,
  host    text not null
);

create table services (
  id    serial primary key,
  name  text not null unique,
  vulns text not null
);

create table vulns (
  id         serial primary key,
  service_id integer not null references services(id),
  n          smallint not null check (n > 0),
  unique (service_id, n)
);

create table rounds (
  n  serial primary key,
  ts timestamptz not null default now()
);

create table flags (
  data       text primary key,
  id         text not null,
  round      integer not null references rounds(n),
  ts         timestamptz not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  vuln_id    integer not null references vulns(id),
  unique (round, team_id, service_id)
);

create table stolen_flags (
  data    text not null references flags(data),
  ts      timestamptz not null default now(),
  round   integer not null references rounds(n),
  team_id integer not null references teams(id),
  amount  float8 not null
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

create function accept_flag(team_id integer, flag_data text, flag_life_time integer) returns record as $$
<<my>>
declare
  flag   flags%rowtype;
  round  rounds.n%type;
  amount stolen_flags.amount%type;

  attacker_pos smallint;
  victim_pos   smallint;
  amount_max   smallint;
begin
  select * from flags where data = flag_data into flag;

  if not found then return row(false, 'Denied: no such flag'); end if;
  if team_id = flag.team_id then return row(false, 'Denied: flag is your own'); end if;

  perform * from stolen_flags as sf where sf.data = flag_data and sf.team_id = accept_flag.team_id;
  if found then return row(false, 'Denied: you already submitted this flag'); end if;

  select max(n) into round from rounds;
  if flag.round <= round - flag_life_time then return row(false, 'Denied: flag is too old'); end if;

  select n from scoreboard as s where s.round = my.round - 1 and s.team_id = accept_flag.team_id into attacker_pos;
  select n from scoreboard as s where s.round = my.round - 1 and s.team_id = flag.team_id into victim_pos;
  select count(*) from teams into amount_max;

  amount = case when attacker_pos >= victim_pos
    then amount_max
    else exp(ln(amount_max) * (victim_pos - amount_max) / (attacker_pos - amount_max))
  end;

  insert into stolen_flags (data, team_id, round, amount) values (flag_data, team_id, round, amount);
  return row(true, null, round, flag.team_id, flag.service_id, amount);
end;
$$ language plpgsql;
-- 1 down
drop function if exists accept_flag(integer, text, integer);
drop table if exists rounds, monitor, scores, teams, vulns, services, flags,
  stolen_flags, runs, sla, flag_points, scoreboard, bots;
