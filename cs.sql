-- 1 up (init)
create table teams (
  id      serial not null primary key,
  name    text not null unique,
  network cidr not null,
  host    text not null
);

create table services (
  id    serial not null primary key,
  name  text not null unique,
  vulns text not null
);

create table vulns (
  id         serial not null primary key,
  service_id integer not null references services(id),
  n          smallint not null check (n > 0),
  unique (service_id, n)
);

create table rounds (
  n  serial not null primary key,
  ts timestamptz not null default now()
);

create table flags (
  data       char(32) primary key,
  id         text not null,
  round      integer not null references rounds(n),
  ts         timestamptz not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  vuln_id    integer not null references vulns(id),
  unique (round, team_id, service_id)
);

create table stolen_flags (
  data    char(32) not null references flags(data),
  ts      timestamptz not null default now(),
  round   integer not null references rounds(n),
  team_id integer not null references teams(id)
);
create or replace function create_stolen_flags()
returns trigger as $$
begin
  select max(n) into new.round from rounds;
  return new;
end;
$$
language plpgsql;
create trigger insert_stolen_flags
  before insert on stolen_flags
  for each row execute procedure create_stolen_flags();
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
  failed     integer not null
);
create index on sla (round);

create table score (
  round      integer not null references rounds(n),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  score      double precision not null
);
create index on score (round);

create table monitor (
  round      integer not null references rounds(n),
  ts         timestamptz not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  status     boolean not null,
  error      text
);

create table scoreboard (
  round    integer not null references rounds(n),
  n        integer  not null,
  team_id  integer not null references teams(id),
  score    double precision not null,
  services jsonb
);
create index on scoreboard (round);
-- 1 down
drop table if exists rounds, monitor, scoreboard, teams, vulns, services, flags, stolen_flags, runs, sla, score;
