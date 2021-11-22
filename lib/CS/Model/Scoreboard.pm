package CS::Model::Scoreboard;
use Mojo::Base 'MojoX::Model';

sub generate {
  my ($self, $round, $limit) = @_;
  my $db = $self->app->pg->db;

  $round //= $db->query('select max(round) from scores')->array->[0];

  my $scoreboard = $db->query('
    select
      t.host, t.network, t.name, s1.n - s.n as d, s.*, s1.services as old_services, s1.score as old_score
    from scoreboard as s
    join teams as t on s.team_id = t.id
    join (
      select * from scoreboard where round = case when $1-1<0 then 0 else $1-1 end
    ) as s1 using (team_id)
    where s.round = $1 order by n limit $2', $round, $limit)
    ->expand->hashes;

  my $services = $db->query('
    select s.id, name, active, extract(epoch from ts_end - now()) as disable_interval
    from service_activity as sa join services as s on sa.service_id = s.id
    where round = ?
  ', $round)->hashes->reduce(sub {
      $a->{$b->{id}} = {name => $b->{name}, active => $b->{active}, disable_interval => $b->{disable_interval}};
      $a
    }, {});

  return {scoreboard => $scoreboard->to_array, round => $round, services => $services};
}

sub generate_history {
  my ($self, $round) = @_;
  my $db = $self->app->pg->db;

  $round //= $db->query('select max(round) from scores')->array->[0];

  my $scoreboard = $db->query(q{
    with a as (
      select *, jsonb_array_elements(services) s
      from scoreboard where round <= $1
    ),
    b as (
      select round, team_id, max(score) score,
        json_agg(json_build_object('flags', s->'flags', 'sflags', s->'sflags', 'fp', s->'fp', 'status', s->'status') order by s->'id') services
      from a
      group by round, team_id
    )
    select round, json_agg(json_build_object('id', team_id, 'score', score, 'services', services)) scoreboard
    from b
    group by round order by round
  }, $round)->expand->hashes;

  return $scoreboard->to_array;
}

sub generate_for_team {
  my ($self, $team_id) = @_;
  my $db = $self->app->pg->db;

  my $round      = $db->query('select max(round) from scores')->array->[0];
  my $scoreboard = $db->query(
    q{
    select t.host, t.name, s.*
    from scoreboard as s
    join teams as t on s.team_id = t.id
    where team_id = $1 order by round desc
  }, $team_id
  )->expand->hashes;

  return {scoreboard => $scoreboard->to_array, round => $round};
}

sub generate_ctftime {
  return shift->app->pg->db->query(<<SQL
    select json_build_object('standings', json_agg(x)::jsonb)
    from (
      select n as pos, t.name as team, score
      from scoreboard as s join teams as t on s.team_id = t.id
      where round = (select max(round) from scoreboard)
      order by score desc
    ) as x
SQL
  )->expand->array->[0];
}

sub generate_fb {
  return shift->app->pg->db->query(<<SQL
    select
      (select name from services where id = service_id) as service,
      (select name from teams where id = team_id) as team,
      (select name from teams where id = victim_id) as victim_team,
      round, ts
    from (
      select
        sf.round, sf.ts, service_id, sf.team_id, f.team_id as victim_id,
        row_number() over (partition by service_id order by sf.ts) as flags
      from stolen_flags as sf join flags as f using(data)
    ) tmp
    where flags = 1
    order by service_id
SQL
  )->hashes->to_array;
}

1;
