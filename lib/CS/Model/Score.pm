package CS::Model::Score;
use Mojo::Base 'MojoX::Model';

use List::Util 'min';

sub update {
  my ($self, $round) = @_;

  my $db = $self->app->pg->db;
  my $tx = $db->begin;
  unless ($db->query('select pg_try_advisory_xact_lock(1)')->array->[0]) {
    $self->app->log->warn("Can't update scores, another update in action");
    return;
  }

  my $r = $db->select(scores => 'max(round) + 1')->array->[0] // 0;
  $round //= $db->select(rounds => 'max(n) - 1')->array->[0];
  for ($r .. $round) {
    $self->sla($db, $_);
    $self->flag_points($db, $_);
    $self->scoreboard($db, $_);
  }
  $tx->commit;
}

sub scoreboard {
  my ($self, $db, $r) = @_;
  $self->app->log->info("Calc scoreboard for round #$r");
  $db->query(
    q{
    insert into scores
    select
      $1 as round, team_id, service_id, sla, fp,
      coalesce(f.flags, 0) as flags, coalesce(sf.flags, 0) as sflags, coalesce(status, 110), stdout
    from
      (select team_id, service_id, amount as fp from flag_points where round = $1) as fp
      join (
        select team_id, service_id,
        case when successed + failed = 0 then 1 else (successed::float8 / (successed + failed)) end as sla
        from sla where round = $1
      ) as s using (team_id, service_id)
      left join (
        select sf.team_id, f.service_id, count(sf.data) as flags
        from stolen_flags as sf join flags as f using (data)
        where sf.round <= $1
        group by sf.team_id, f.service_id
      ) as f using (team_id, service_id)
      left join (
        select f.team_id, f.service_id, count(sf.data) as flags
        from stolen_flags as sf join flags as f using (data)
        where sf.round <= $1
        group by f.team_id, f.service_id
      ) as sf using (team_id, service_id)
      left join (
        select team_id, service_id, status, stdout from runs where round = $1
      ) as r using (team_id, service_id)
    }, $r
  );
  $db->query(
    q{
    insert into scoreboard
    select round, team_id, round(sum(sla * fp)::numeric, 2) as score,
      rank() over(order by sum(sla * fp) desc) as n,
      json_agg(json_build_object(
        'id', service_id,
        'flags', flags,
        'sflags', sflags,
        'fp', round(fp::numeric, 2),
        'sla', round(100 * sla::numeric, 2),
        'status', status,
        'stdout', stdout
      ) order by service_id) as services
    from scores where round = $1 group by round, team_id;
    }, $r
  );
}

sub sla {
  my ($self, $db, $r) = @_;
  $self->app->log->info("Calc SLA for round #$r");

  my $state = $db->select(sla => '*', {round => $r - 1})
    ->hashes->reduce(sub { ++$b->{round}; $a->{$b->{team_id}}{$b->{service_id}} = $b; $a; }, {});

  $db->query('
    with r as (select team_id, service_id, status from runs where round = ?),
    teams_x_services as (
      select teams.id as team_id, services.id as service_id
      from teams cross join services
    )
    select * from teams_x_services left join r using (team_id, service_id)', $r)->hashes->map(
    sub {
      my $status = $_->{status} // 110;

      # Skip inactive services or checker errors
      return if $status == 111 || $status == 110;

      my $field = $status == 101 ? 'successed' : 'failed';
      ++$state->{$_->{team_id}}{$_->{service_id}}{$field};
    }
  );

  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      $db->insert(sla => $state->{$team_id}{$service_id});
    }
  }
}

sub flag_points {
  my ($self, $db, $r) = @_;
  $self->app->log->info("Calc FP for round #$r");

  my $state = $db->select(flag_points => '*', {round => $r - 1})
    ->hashes->reduce(sub { ++$b->{round}; $a->{$b->{team_id}}{$b->{service_id}} = $b; $a; }, {});
  my $flags = $db->query(q{
    select f.data, f.service_id, f.team_id as victim_id, sf.team_id, sf.amount
    from flags as f join stolen_flags as sf using (data)
    where sf.round = ? order by sf.ts asc
  }, $r)->hashes;

  for my $flag (@$flags) {
    $state->{$flag->{team_id}}{$flag->{service_id}}{amount} += $flag->{amount};
    $state->{$flag->{victim_id}}{$flag->{service_id}}{amount} -=
      min($flag->{amount}, $state->{$flag->{victim_id}}{$flag->{service_id}}{amount});
  }

  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      $db->insert(flag_points => $state->{$team_id}{$service_id});
    }
  }
}

1;
