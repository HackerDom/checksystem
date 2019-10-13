package CS::Controller::Admin;
use Mojo::Base 'Mojolicious::Controller';

use List::Util 'all';
use Mojo::Util 'b64_decode', 'tablify';

sub auth {
  my $c = shift;

  my $auth = $c->req->headers->authorization // '';
  unless ($auth) {
    $c->res->headers->www_authenticate('Basic');
    $c->render(text => 'Authentication required!', status => 401);
    return undef;
  }
  $auth =~ s/^Basic\s//;
  my $line = b64_decode $auth;

  return 1 if $line eq $c->config->{cs}{admin}{auth};

  $c->res->headers->www_authenticate('Basic');
  $c->render(text => 'Authentication required!', status => 401);
  return undef;
}

sub info {
  my $c = shift;
  my $db = $c->pg->db;

  # Game status
  my $time = $c->config->{cs}{time};
  my $range = join ',', map "'[$_->[0], $_->[1]]'", @$time;
  my $sql = <<"SQL";
    with tmp as (
      select *, (select max(n) from rounds where ts < lower(range)) as r
      from (select unnest(array[$range]::tstzrange[]) as range) as tmp
    )
    select
      range, r + 1,
      now() <@ range as live,
      now() < lower(range) as before,
      now() > upper(range) as finish
    from tmp
SQL
  my $game_status = $c->_tablify($db->query($sql));

  # Services
  my $services = $c->_tablify($db->query('table services'));

  # Installed flags
  $sql = '
  select
    (select name from services where id = service_id) as service, vuln_id, count(*) as flags
  from flags
  where ack = true
  group by service_id, vuln_id order by 1, 2
';
  my $installed_flags = $c->_tablify($db->query($sql));

  # Stolen flags
  $sql = '
  select
    (select name from services where id = service_id) as service,
    vuln_id, grouping(vuln_id), count(*), avg(amount) as avg_amount,
    percentile_disc(0.99) within group (order by amount) as percentile99,
    percentile_disc(0.90) within group (order by amount) as percentile90,
    percentile_disc(0.75) within group (order by amount) as percentile75
  from stolen_flags join flags using (data)
  group by grouping sets((service_id), (service_id, vuln_id))
  order by 3 desc, 4 desc
';
  my $stolen_flags = $c->_tablify($db->query($sql));

  # First bloods
  $sql = '
  with tmp as (
    select
      sf.round, sf.ts, service_id, sf.team_id,
      row_number() over (partition by service_id order by sf.ts) as flags
    from stolen_flags as sf join flags as f using(data)
  )
  select
    (select name from services where id = service_id) as service,
    (select name from teams where id = team_id) as team,
    flags, round, ts
  from tmp
  where flags in (1, 10, 100, 1000, 10000)
  order by service_id
';
  my $fb = $c->_tablify($db->query($sql));

  $c->render(
    now => scalar(localtime),
    game_status => $game_status,
    tables => [
      {name => 'Installed flags', data => $installed_flags},
      {name => 'Stolen flags',    data => $stolen_flags},
      {name => 'First bloods',    data => $fb},
      {name => 'Services',        data => $services}
    ]
  );
}

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub view {
  my $c  = shift;
  my $db = $c->pg->db;

  my $team    = $c->app->teams->{$c->param('team_id')};
  my $service = $c->app->services->{$c->param('service_id')};

  return $c->reply->not_found
    unless ($team->{id} || ($c->param('team_id') eq '*'))
    && ($service->{id} || ($c->param('service_id') eq '*'));

  my $status = $c->param('status');
  if ($status) {
    $status = undef if $status eq 'all' || all { $status != $_ } (101, 102, 103, 104, 110);
  }

  my $last = $db->query(
    'select count(*)
    from runs where
    (team_id = $1 or $1 is null) and (service_id = $2 or $2 is null) and (status = $3 or $3 is null)',
    $team->{id}, $service->{id}, $status
  )->array->[0];
  my $limit = int($c->param('limit') // 0) || 30;
  my $max   = int($last / $limit) + 1;

  my $page = int($c->param('page') // 1);
  $page = 1    if $page < 1;
  $page = $max if $page > $max;
  my $offset = ($page - 1) * $limit;

  my $view = $db->query(
    'select round, status, result
    from runs where
    (team_id = $1 or $1 is null) and (service_id = $2 or $2 is null) and (status = $3 or $3 is null)
    order by round desc limit $4 offset $5', $team->{id}, $service->{id}, $status, $limit, $offset
  )->expand->hashes->to_array;
  $c->render(view => $view, page => $page, max => $max);
}

sub _tablify {
  my ($c, $result) = @_;

  my $r = $result->arrays;
  unshift @$r, $result->columns;
  return tablify($r);
}

1;
