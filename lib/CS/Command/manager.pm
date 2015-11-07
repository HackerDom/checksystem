package CS::Command::manager;
use Mojo::Base 'Mojolicious::Command';

use List::Util 'first';
use Time::Piece;
use Time::Seconds;

has description => 'Run CTF game';

has round => sub { $_[0]->app->pg->db->query('select max(n) from rounds')->array->[0] };

sub run {
  my $self = shift;
  my $app  = $self->app;

  local $SIG{INT} = local $SIG{TERM} =
    sub { $app->log->info('Gracefully stopping manager. Wait for new round...'); $self->{finished}++ };

  $app->pg->pubsub->listen(job_finish => sub { $self->finalize_check($app->minion->job($_[1])) });

  my $now = localtime;
  my $start = localtime(Time::Piece->strptime($app->config->{cs}{time}{start}, $app->model('util')->format));
  my $round_length = $app->config->{cs}{round_length};
  Mojo::IOLoop->timer(
    ($now < $start ? ($start - $now)->seconds : $round_length) => sub {
      Mojo::IOLoop->recurring($round_length => sub { $self->start_round });
      $self->start_round;
    }
  );

  Mojo::IOLoop->recurring(15 => sub { $app->minion->enqueue('scoreboard') });
  Mojo::IOLoop->start;
}

sub start_round {
  my $self = shift;
  my ($app, $ids) = ($self->app);

  exit if $self->{finished};

  # Check end of game
  if ($app->model('util')->game_status == -1) {
    $app->minion->enqueue($_ => [$self->round]) for (qw/sla flag_points/);
  }
  return unless $app->model('util')->game_status == 1;

  $app->minion->enqueue($_) for (qw/sla flag_points/);

  my $round = $app->pg->db->query('insert into rounds default values returning n')->hash->{n};
  $self->round($round);
  $app->log->debug("Start new round #$round");

  for my $team (values %{$app->teams}) {
    for my $service (values %{$app->services}) {
      my $n       = $service->{vulns}->[$round % @{$service->{vulns}}];
      my $vuln_id = $app->vulns->{$service->{id}}{$n};

      my $flag     = $app->model('flag')->create;
      my $old_flag = $app->pg->db->query(
        'select id, data from flags
        where team_id = ? and vuln_id = ? and round >= ? order by random() limit 1',
        ($team->{id}, $vuln_id, $round - $app->config->{cs}{flag_life_time})
      )->hash;
      my $id = $app->minion->enqueue(
        check => [$round, $team, $service, $flag, $old_flag, {n => $n, id => $vuln_id}]);
      push @$ids, $id;
      $app->log->debug("Enqueue new job for $team->{name}/$service->{name}/$n: $id");
    }
  }

  return $ids;
}

sub finalize_check {
  my ($self, $job, $status) = @_;
  my $app = $self->app;

  my $result = $job->info->{result};
  my ($round, $team, $service, $flag, undef, $vuln) = @{$job->args};

  if (!$result->{check} || $round != $self->round) {
    $result->{error} = 'Job is too old!';
    $status = 110;
  } else {
    $status = $result->{first { defined $result->{$_}{exit_code} } (qw/get_2 get_1 put check/)}{exit_code};
  }

  # Save result
  eval {
    $app->pg->db->query(
      'insert into runs (round, team_id, service_id, vuln_id, status, result) values (?, ?, ?, ?, ?, ?)',
      $round, $team->{id}, $service->{id}, $vuln->{id}, $status, {json => $result});
  };
  $app->log->error("Error while insert check result: $@") if $@;

  # Check, put and get was ok, save flag
  return unless ($result->{get_1}{exit_code} // 0) == 101;
  my $id = $result->{put}{fid} // $flag->{id};
  eval {
    $app->pg->db->query(
      'insert into flags (data, id, round, team_id, service_id, vuln_id) values (?, ?, ?, ?, ?, ?)',
      $flag->{data}, $id, $self->round, $team->{id}, $service->{id}, $vuln->{id});
  };
  $app->log->error("Error while insert flag: $@") if $@;
}

1;
