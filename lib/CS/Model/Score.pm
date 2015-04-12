package CS::Model::Score;
use Mojo::Base 'MojoX::Model';

use List::Util 'min';

has dimension => sub { keys(%{$_[0]->app->teams}) * keys(%{$_[0]->app->services}) };

sub sla {
  my $self = shift;
  my $app  = $self->app;
  my $db   = $app->pg->db;

  my $r = 1 + ($db->query('select max(round) as n from sla')->hash->{n} // 0);
  $app->log->debug("Attempt calc SLA for round #$r");

  # Check for new round
  return unless $db->query('select * from rounds where n > ?', $r)->rows;
  $app->log->debug("Calc SLA for round #$r");

  my $state = $db->query('select * from sla where round = ?', $r - 1)->hashes->reduce(
    sub {
      $a->{$b->{team_id}}{$b->{service_id}} = $b;
      $a;
    },
    {}
  );

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
  my $self = shift;
  my $app  = $self->app;
  my $db   = $app->pg->db;

  my $r = 1 + $db->query('select max(round) as n from score')->hash->{n};
  $app->log->debug("Attempt calc FP for round #$r");

  # Check for new round
  return unless $db->query('select * from rounds where n > ?', $r)->rows;

  # There is non-rotten flags
  my $res = $db->query('select extract(epoch from now()-ts) from flags where round = ? order by ts desc', $r);
  return if $res->rows && $res->array->[0] < $app->config->{cs}{flag_expire_interval};
  $app->log->debug("Calc FP for round #$r");

  my $state = $db->query('select * from score where round = ?', $r - 1)->hashes->reduce(
    sub {
      $a->{$b->{team_id}}{$b->{service_id}} = $b->{score};
      $a;
    },
    {}
  );

  $db->query('
    select flags.data, array_agg(stolen_flags.team_id) as teams, flags.service_id, flags.team_id
    from flags join stolen_flags using (data)
    where round = ? group by data order by flags.ts
    ', $r)->hashes->map(
    sub {
      my $jackpot = min $state->{$_->{team_id}}{$_->{service_id}}, 0 + keys %{$app->teams};
      my $part = $jackpot / @{$_->{teams}};
      for my $team_id (@{$_->{teams}}) {
        $state->{$team_id}{$_->{service_id}} += $part;
      }
      $state->{$_->{team_id}}{$_->{service_id}} -= $jackpot;
    }
  );

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
