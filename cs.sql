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
  ts timestamp with time zone not null default now()
);

create table flags (
  data       char(32) primary key,
  id         text not null,
  round      integer not null references rounds(n),
  ts         timestamp with time zone not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  vuln_id    integer not null references vulns(id),
  unique (round, team_id, service_id)
);

create table stolen_flags (
  data    char(32) not null references flags(data),
  ts      timestamp with time zone not null default now(),
  team_id integer not null references teams(id)
);

create table runs (
  round      integer not null references rounds(n),
  ts         timestamp with time zone not null default now(),
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
  ts         timestamp with time zone not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  status     boolean not null,
  error      text
);

create materialized view scoreboard as (
  with fp as (
    select distinct on (team_id, service_id) team_id, service_id, score
    from score order by team_id, service_id, round desc
  ),
  s as (
    select distinct on (team_id, service_id) team_id, service_id,
    case when successed + failed = 0 then 1 else (successed::double precision / (successed + failed)) end as sla
    from sla order by team_id, service_id, round desc
  ),
  f as (
    select sf.team_id, f.service_id, count(sf.data) as flags
    from stolen_flags as sf join flags as f using (data)
    group by sf.team_id, f.service_id
  ),
  r as (
    select distinct on (team_id, service_id) team_id, service_id, status, stdout
    from runs order by team_id, service_id, round desc
  ),
  sc as (
    select
      fp.team_id, round(sum(sla * score)::numeric, 2) as score,
      json_agg(json_build_object(
        'id', fp.service_id,
        'flags', coalesce(f.flags, 0),
        'fp', round(fp.score::numeric, 2),
        'sla', round(100 * s.sla::numeric, 2),
        'status', status,
        'stdout', stdout
      ) order by id) as services
    from fp join s using (team_id, service_id)
      left join f using (team_id, service_id)
      left join r using (team_id, service_id)
      join services on fp.service_id = services.id
    group by team_id
  )
  select rank() over(order by score desc) as n,
    teams.name as name, teams.host, sc.*
  from sc join teams on sc.team_id = teams.id
  order by score desc
);
create unique index scoreboard_row on scoreboard (team_id);

create materialized view scoreboard_history as (
  with score_by_round as (
    select round, team_id,
    round(sum(score * (case when successed + failed = 0 then 1
      else (successed::double precision / (successed + failed)) end))::numeric, 2) as score
    from score join sla using (round, team_id, service_id)
    group by round, team_id
  ),
  s as (
    select *, rank() over(partition by round order by score desc) as n
    from score_by_round
  ),
  tmp as (
    select team_id as team_id,
    array_agg(score order by round) as scores,
    array_agg(n order by round) as position
    from s
    group by team_id
  )
  select teams.name as team_name, tmp.*
  from tmp join teams on tmp.team_id = teams.id
);
create unique index scoreboard_history_row on scoreboard_history (team_id);
-- 1 down
drop materialized view if exists scoreboard, scoreboard_history;
drop table if exists rounds, monitor, teams, vulns, services, flags, stolen_flags, runs, sla, score;
