package CS::Model::Score;
use Mojo::Base 'MojoX::Model';

use List::Util 'min';

sub update {
  my ($self, $round) = @_;

  my $db = $self->app->pg->db;
  my $r = $db->query('select max(round) + 1 from scores')->array->[0] // 0;
  $round //= $db->query('select max(n) - 1 from rounds')->array->[0];
  for ($r .. $round) {
    my $tx = $db->begin;
    $self->sla($db, $_);
    $self->flag_points($db, $_);
    $self->scoreboard($db, $_);
    $tx->commit;
  }
}

sub scoreboard {
  my ($self, $db, $r) = @_;
  $self->app->log->debug("Calc scoreboard for round #$r");
  $db->query(
    q{
    insert into scores
    select
      $1 as round, team_id, service_id, sla, fp, coalesce(f.flags, 0) as flags, coalesce(status, 110), stdout
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
        select team_id, service_id, status, stdout from runs where round = $1
      ) as r using (team_id, service_id)
}, $r
  );
}

sub sla {
  my ($self, $db, $r) = @_;
  $self->app->log->debug("Calc SLA for round #$r");

  my $state = $db->query('select * from sla where round = ?', $r - 1)
    ->hashes->reduce(sub { $a->{$b->{team_id}}{$b->{service_id}} = $b; $a; }, {});

  $db->query('
    with r as (select team_id, service_id, status from runs where round = ?),
    teams_x_services as (
      select teams.id as team_id, services.id as service_id
      from teams cross join services
    )
    select * from teams_x_services left join r using (team_id, service_id)', $r)->hashes->map(
    sub {
      my $field = ($_->{status} // 110) == 101 ? 'successed' : 'failed';
      ++$state->{$_->{team_id}}{$_->{service_id}}{$field};
    }
  );

  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      my $s = $state->{$team_id}{$service_id};
      my $sql = 'insert into sla (round, team_id, service_id, successed, failed) values (?, ?, ?, ?, ?)';
      $db->query($sql, $r, $team_id, $service_id, $s->{successed}, $s->{failed});
    }
  }
}

sub flag_points {
  my ($self, $db, $r) = @_;
  $self->app->log->debug("Calc FP for round #$r");

  my $state = $db->query('select * from flag_points where round = ?', $r - 1)
    ->hashes->reduce(sub { $a->{$b->{team_id}}{$b->{service_id}} = $b->{amount}; $a; }, {});
  my $flags = $db->query('
    select f.data, f.service_id, f.team_id as victim_id, sf.team_id
    from flags as f join stolen_flags as sf using (data) where sf.round = ?
    ', $r)->hashes;
  my $scoreboard = $db->query('
    select team_id, rank() over(order by sum(sla * fp) desc) as n
    from scores where round = ? group by team_id
    ', $r - 1)->hashes->reduce(sub { $a->{$b->{team_id}} = $b->{n}; $a; }, {});

  for my $flag (@$flags) {
    my $amount = $self->app->model('flag')->amount($scoreboard, @{$flag}{qw/victim_id team_id/});
    $state->{$flag->{team_id}}{$flag->{service_id}} += $amount;
    $state->{$flag->{victim_id}}{$flag->{service_id}} -=
      min($amount, $state->{$flag->{victim_id}}{$flag->{service_id}});
  }

  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      my $sql = 'insert into flag_points (round, team_id, service_id, amount) values (?, ?, ?, ?)';
      $db->query($sql, $r, $team_id, $service_id, $state->{$team_id}{$service_id});
    }
  }
}

sub scoreboard_info {
  my $self = shift;
  my $db   = $self->app->pg->db;

  my $round = $db->query('select max(round) from scoreboard')->array->[0];
  my $scoreboard = $db->query('select team_id, n from scoreboard where round = ?', $round)
    ->hashes->reduce(sub { $a->{$b->{team_id}} = $b->{n}; $a; }, {});
  return {scoreboard => $scoreboard, round => $round};
}

1;
