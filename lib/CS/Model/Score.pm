package CS::Model::Score;
use Mojo::Base 'MojoX::Model';

use List::Util 'min';

has dimension => sub { keys(%{$_[0]->app->teams}) * keys(%{$_[0]->app->services}) };

sub sla {
  my ($self, $round) = @_;
  my $app = $self->app;
  my $db  = $app->pg->db;

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
  my $app = $self->app;
  my $db  = $app->pg->db;

  my $r = $db->query('select max(round) + 1 from score')->array->[0];
  $round //= $db->query('select max(n) - 1 - ? from rounds', $app->config->{cs}{flag_life_time})->array->[0];
  $self->_flag_points($_) for $r .. $round;
}

sub _flag_points {
  my ($self, $r) = @_;
  $self->app->log->debug("Calc FP for round #$r");

  my $db = $self->app->pg->db;
  my $state = $db->query('select * from score where round = ?', $r - 1)
    ->hashes->reduce(sub { $a->{$b->{team_id}}{$b->{service_id}} = $b->{score}; $a; }, {});
  my $flags = $db->query('
    select flags.data, array_agg(stolen_flags.team_id) as teams, flags.service_id, flags.team_id
    from flags join stolen_flags using (data)
    where round = ? group by data order by flags.ts
    ', $r)->hashes;

  my $scoreboard = $db->query(
    'select rank() over(order by score desc) as n, team_id, score
      from (select team_id,
          round(sum(100 * score * (case when successed + failed = 0 then 1
          else (successed::double precision / (successed + failed)) end))::numeric, 2) as score
      from score join sla using (round, team_id, service_id)
      where round = ?
      group by team_id) as tmp', $r - 1
  )->hashes->reduce(sub { $a->{$b->{team_id}} = $b->{n}; $a; }, {});
  $flags->map(
    sub {
      my $jackpot   = 0 + keys %{$self->app->teams};
      my $victim_id = $_->{team_id};
      for my $team_id (@{$_->{teams}}) {
        my $amount;
        if ($scoreboard->{$team_id} >= $scoreboard->{$victim_id}) {
          $amount = $jackpot;
        } else {
          my $n = $scoreboard->{$team_id};
          my $j = log $jackpot;
          $amount = exp($j - $j * $n / ($n - $jackpot) + $j / ($n - $jackpot) * $scoreboard->{$victim_id});
        }
        $state->{$team_id}{$_->{service_id}} += $amount;
      }
      $state->{$victim_id}{$_->{service_id}} -= $jackpot;
    }
  );

  # $flags->map(
  #   sub {
  #     my $jackpot = min $state->{$_->{team_id}}{$_->{service_id}}, 0 + keys %{$self->app->teams};
  #     my $amount = $jackpot / @{$_->{teams}};
  #     for my $team_id (@{$_->{teams}}) {
  #       $state->{$team_id}{$_->{service_id}} += $amount;
  #     }
  #     $state->{$_->{team_id}}{$_->{service_id}} -= $jackpot;
  #   }
  # );
  $self->_update_score_state($r, $state);
}

sub _update_sla_state {
  my ($self, $r, $state) = @_;

  my @params;
  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      my $s = $state->{$team_id}{$service_id};
      push @params, $r, $team_id, $service_id, $s->{successed} // 0, $s->{failed} // 0;
    }
  }
  $self->app->pg->db->query(
    sprintf('insert into sla (round, team_id, service_id, successed, failed) values %s',
      join(', ', ('(?, ?, ?, ?, ?)') x $self->dimension)),
    @params
  );
}

sub _update_score_state {
  my ($self, $r, $state) = @_;

  my @params;
  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      push @params, $r, $team_id, $service_id, $state->{$team_id}{$service_id};
    }
  }
  $self->app->pg->db->query(
    sprintf('insert into score (round, team_id, service_id, score) values %s',
      join(', ', ('(?, ?, ?, ?)') x $self->dimension)),
    @params
  );
}

1;
