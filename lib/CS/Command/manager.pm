package CS::Command::manager;
use Mojo::Base 'Mojolicious::Command';

use List::Util 'max';
use Mojo::Collection 'c';

has description => 'Run CTF game';

has round => sub { $_[0]->app->pg->db->select(rounds => 'max(n)')->array->[0] };

sub run {
  my $self = shift;
  my $app  = $self->app;

  my $start = $app->model('util')->game_time->{start} // 0;

  my $sleep;
  if (time < $start) { $sleep = $start - time }
  else {
    my $round_start =
      $app->round_length + $app->pg->db->select(rounds => 'extract(epoch from max(ts))')->array->[0];
    $sleep = time > $round_start ? 0 : $round_start - time;
  }

  Mojo::IOLoop->timer(
    $sleep => sub {
      Mojo::IOLoop->recurring($app->round_length => sub { $self->start_round });
      $self->start_round;
    }
  );
  Mojo::IOLoop->start;
}

sub start_round {
  my $self = shift;
  my $app  = $self->app;

  # Check end of game
  my ($game_status, $init_round) = $app->model('util')->game_status;
  $app->minion->enqueue(scoreboard => [$self->round]) if $game_status == -1;
  return unless $game_status == 1;

  my $db = $app->pg->db;
  my $round = $db->insert('rounds', {n => \'(select max(n)+1 from rounds)'}, {returning => 'n'})->hash->{n};
  $self->round($round);
  $app->minion->enqueue(scoreboard => [] => {delay => 10});
  $app->log->debug("Start new round #$round");

  my $status = $self->get_monitor_status;
  my $active_services = $app->model('util')->update_service_phases($round);

  my $check_round = $round - $app->flag_life_time;
  if ($init_round && $init_round > 1) {
    $check_round = max($check_round, $init_round - 1);
  }
  $db->query(q{
    update flags set expired = true
    where expired = false and round <= ?
  }, $check_round);

  my $alive_flags = $db->query(q{
    select team_id, vuln_id, json_agg(json_build_object('id', id, 'data', data)) as flags
    from flags
    where ack = true and expired = false
    group by team_id, vuln_id
  })->expand->hashes->reduce(sub { $a->{$b->{team_id}}{$b->{vuln_id}} = $b->{flags}; $a; }, {});

  my $teams = $db->select('teams', ['id'])->arrays->flatten;
  for my $team_id (@$teams) {
    for my $service (values %{$app->services}) {
      my $service_id = $service->{id};
      my $n       = $service->{vulns}->[$round % @{$service->{vulns}}];
      my $vuln_id = $app->vulns->{$service_id}{$n};

      if (!$active_services->{$service_id}) {
        $self->skip_check({team_id => $team_id, service_id => $service_id, vuln_id => $vuln_id}, 111, 'Service was disabled.');
        $app->log->debug("Skip service #$service_id in round #$round for team #$team_id");
        next;
      }

      if (my $s = $status->{$team_id}{$service_id}) {
        if ($round - $s->{round} <= 1 && !$s->{status}) {
          $self->skip_check({team_id => $team_id, service_id => $service_id, vuln_id => $vuln_id});
          next;
        }
      }

      my $flag     = $app->model('flag')->create($team_id);
      my $old_flag = c(@{$alive_flags->{$team_id}{$vuln_id}})->shuffle->first;

      $app->minion->enqueue(
        check => [$round, $team_id, $service_id, $flag, $old_flag, {n => $n, id => $vuln_id}]
      );
    }
  }
}

sub get_monitor_status {
  my $self = shift;

  return $self->app->pg->db->query(
    'select distinct on (team_id, service_id) *
    from monitor order by team_id, service_id, ts desc'
  )->hashes->reduce(
    sub { $a->{$b->{team_id}}{$b->{service_id}} = {round => $b->{round}, status => $b->{status}}; $a }, {}
  );
}

sub skip_check {
  my ($self, $info, $code, $message) = @_;
  $code //= 104;
  $message //= 'Checker did not run, connect on port was failed.';

  $self->app->pg->db->query(
    'insert into runs (round, team_id, service_id, vuln_id, status, result) values (?, ?, ?, ?, ?, ?)',
    $self->round, $info->{team_id}, $info->{service_id}, $info->{vuln_id}, $code,
    {json => {error => $message}}
  );
}

1;
