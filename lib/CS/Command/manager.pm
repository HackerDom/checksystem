package CS::Command::manager;
use Mojo::Base 'Mojolicious::Command';

use Mojo::Collection 'c';
use Time::Piece;
use Time::Seconds;

has description => 'Run CTF game';

has round => sub { $_[0]->app->pg->db->select(rounds => 'max(n)')->array->[0] };

sub run {
  my $self = shift;
  my $app  = $self->app;

  my $now = localtime;
  my $start = $app->model('util')->game_time->{start};
  my $round_length = $app->config->{cs}{round_length};

  my $sleep;
  if ($now < $start) { $sleep = ($start - $now)->seconds }
  else {
    my $round_start =
      $round_length + $app->pg->db->select(rounds => 'extract(epoch from max(ts))')->array->[0];
    $sleep = time > $round_start ? 0 : $round_start - time;
  }

  Mojo::IOLoop->timer(
    $sleep => sub {
      Mojo::IOLoop->recurring($round_length => sub { $self->start_round });
      $self->start_round;
    }
  );
  Mojo::IOLoop->start;
}

sub start_round {
  my $self = shift;
  my $app  = $self->app;

  # Check end of game
  $app->minion->enqueue(scoreboard => [$self->round]) if $app->model('util')->game_status == -1;
  return unless $app->model('util')->game_status == 1;

  my $db = $app->pg->db;
  my $round = $db->insert('rounds', \'default values', {returning => 'n'})->hash->{n};
  $self->round($round);
  $app->minion->enqueue('scoreboard');
  $app->log->info("Start new round #$round");
  $app->metric->write('round', 1, {n => $round});

  my $status = $db->query(
    'select distinct on (team_id, service_id) *
    from monitor order by team_id, service_id, ts desc'
    )
    ->hashes->reduce(
    sub { $a->{$b->{team_id}}{$b->{service_id}} = {round => $b->{round}, status => $b->{status}}; $a; }, {});
  my $flags = $db->query(
    "select team_id, vuln_id, json_agg(json_build_object('id', id, 'data', data)) as flags
    from flags where round >= ? group by team_id, vuln_id", $round - $app->config->{cs}{flag_life_time}
  )->expand->hashes->reduce(sub { $a->{$b->{team_id}}{$b->{vuln_id}} = $b->{flags}; $a; }, {});

  for my $team (values %{$app->teams}) {
    for my $service (values %{$app->services}) {
      my $n       = $service->{vulns}->[$round % @{$service->{vulns}}];
      my $vuln_id = $app->vulns->{$service->{id}}{$n};
      my ($team_id, $service_id) = ($team->{id}, $service->{id});

      if (my $s = $status->{$team_id}{$service_id}) {
        if ($self->round - $s->{round} <= 1 && !$s->{status}) {
          $self->skip_check(
            {round => $self->round, team_id => $team_id, service_id => $service_id, vuln_id => $vuln_id});
          $app->log->debug("Skip job for $team->{name}/$service->{name}/$n");
          next;
        }
      }

      my $flag     = $app->model('flag')->create;
      my $old_flag = c(@{$flags->{$team_id}{$vuln_id}})->shuffle->first;
      my $id       = $app->minion->enqueue(
        check => [$round, $team, $service, $flag, $old_flag, {n => $n, id => $vuln_id}],
        {queue => $app->config->{queues}{$team->{name}}{$service->{name}} // 'checker'}
      );
      $app->log->debug("Enqueue new job for $team->{name}/$service->{name}/$n: $id");
    }
  }
}

sub skip_check {
  my ($self, $info) = @_;

  eval {
    $self->app->pg->db->query(
      'insert into runs (round, team_id, service_id, vuln_id, status, result) values (?, ?, ?, ?, ?, ?)',
      $info->{round}, $info->{team_id}, $info->{service_id}, $info->{vuln_id}, 104,
      {json => {error => 'Checker did not run, connect on port was failed.'}}

    );
  };
  $self->app->log->error("Error while insert check result: $@") if $@;
}

1;
