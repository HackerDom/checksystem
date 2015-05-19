-- 1 up (init)
create table teams (
  id      serial not null primary key,
  name    text not null unique,
  network cidr not null,
  host    inet not null
);

create table services (
  id   serial not null primary key,
  name text not null unique
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
  service_id integer not null references services(id)
);

create table stolen_flags (
  data              char(32) not null references flags(data),
  ts                timestamp with time zone not null default now(),
  team_id           integer not null references teams(id)
);

create table runs (
  round      integer not null references rounds(n),
  ts         timestamp with time zone not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  status     integer not null,
  result     json
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

create table achievement (
  ts   timestamp with time zone not null default now(),
  data text
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
    select distinct on (team_id, service_id) team_id, service_id, status, result
    from runs order by team_id, service_id, round desc
  ),
  sc as (
    select
      fp.team_id, round(sum(100 * sla * score)::numeric, 2) as score,
      json_agg(json_build_object(
        'id', fp.service_id,
        'flags', coalesce(f.flags, 0),
        'fp', round(fp.score::numeric, 2),
        'sla', round(100 * s.sla::numeric, 2),
        'status', status,
        'result', result
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
