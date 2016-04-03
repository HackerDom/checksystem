package CS::Model::Score;
use Mojo::Base 'MojoX::Model';

use List::Util 'min';

sub sla {
  my ($self, $round) = @_;
  my $db = $self->app->pg->db;

  my $r = $db->query('select max(round) + 1 from sla')->array->[0];
  $round //= $db->query('select max(n) - 1 from rounds')->array->[0];
  $self->_sla($_) for $r .. $round;
}

sub _sla {
  my ($self, $r) = @_;
  $self->app->log->debug("Calc SLA for round #$r");

  my $db = $self->app->pg->db;
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

  $self->_update_sla_state($r, $state);
}

sub flag_points {
  my ($self, $round) = @_;
  my $db = $self->app->pg->db;

  my $r = $db->query('select max(round) + 1 from score')->array->[0];
  $round //= $db->query('select max(n) - 1 from rounds')->array->[0];
  $self->_flag_points($_) for $r .. $round;
}

sub _flag_points {
  my ($self, $r) = @_;
  $self->app->log->debug("Calc FP for round #$r");

  my $db = $self->app->pg->db;
  my $state = $db->query('select * from score where round = ?', $r - 1)
    ->hashes->reduce(sub { $a->{$b->{team_id}}{$b->{service_id}} = $b->{score}; $a; }, {});
  my $flags = $db->query('
    select f.data, f.service_id, f.team_id as victim_id, sf.team_id
    from flags as f join stolen_flags as sf using (data)
    where sf.round = ? order by sf.ts
    ', $r)->hashes;

  my $scoreboard = $db->query(
'select rank() over(order by score desc rows between unbounded preceding and unbounded following) as n, team_id
      from (select team_id,
          round(sum(100 * score * (case when successed + failed = 0 then 1
          else (successed::double precision / (successed + failed)) end))::numeric, 2) as score
      from score join sla using (round, team_id, service_id)
      where round = ?
      group by team_id) as tmp', $r - 1
  )->hashes->reduce(sub { $a->{$b->{team_id}} = $b->{n}; $a; }, {});

  my $jackpot = 0 + keys %{$self->app->teams};
  for my $flag (@$flags) {
    my ($v, $t) = @{$scoreboard}{@{$flag}{qw/victim_id team_id/}};

    my $amount = $t >= $v ? $jackpot : exp(log($jackpot) * ($v - $jackpot) / ($t - $jackpot));
    $state->{$flag->{team_id}}{$flag->{service_id}} += $amount;
    $state->{$flag->{victim_id}}{$flag->{service_id}} -=
      min($amount, $state->{$flag->{victim_id}}{$flag->{service_id}});
  }

  $self->_update_score_state($r, $state);
}

sub _update_sla_state {
  my ($self, $r, $state) = @_;

  my $db = $self->app->pg->db;
  my $tx = $db->begin;
  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      my $s = $state->{$team_id}{$service_id};

      my $sql = 'insert into sla (round, team_id, service_id, successed, failed) values (?, ?, ?, ?, ?)';
      $db->query($sql, $r, $team_id, $service_id, $s->{successed} // 0, $s->{failed} // 0);
    }
  }
  $tx->commit;
}

sub _update_score_state {
  my ($self, $r, $state) = @_;

  my $db = $self->app->pg->db;
  my $tx = $db->begin;
  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      my $sql = 'insert into score (round, team_id, service_id, score) values (?, ?, ?, ?)';
      $db->query($sql, $r, $team_id, $service_id, $state->{$team_id}{$service_id});
    }
  }
  $tx->commit;
}

1;
