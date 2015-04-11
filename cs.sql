-- 1 up (init)
create table teams (
  id      serial not null primary key,
  name    text not null unique,
  network cidr,
  host    inet not null
);

create table services (
  id   serial not null primary key,
  name text not null unique
);

create table rounds (
  n  serial not null primary key,
  ts timestamp not null default now()
);

create table flags (
  data       char(32) primary key,
  id         text not null,
  round      integer not null references rounds(n),
  ts         timestamp not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id)
);

create table stolen_flags (
  data              char(32) not null references flags(data),
  ts                timestamp not null default now(),
  team_id           integer not null references teams(id),
  victim_team_id    integer not null references teams(id),
  victim_service_id integer not null references services(id)
);

create table runs (
  round      integer not null references rounds(n),
  ts         timestamp not null default now(),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  status     integer not null,
  result     json
);

create table sla (
  round      integer not null references rounds(n),
  team_id    integer not null references teams(id),
  service_id integer not null references services(id),
  successed  integer not null,
  failed     integer not null
);
