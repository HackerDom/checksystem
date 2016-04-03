package CS::Command::manager;
use Mojo::Base 'Mojolicious::Command';

use Mojo::Collection 'c';
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

  my $sleep;
  if ($now < $start) { $sleep = ($start - $now)->seconds }
  else {
    my $round_start =
      $round_length + $app->pg->db->query('select extract(epoch from max(ts)) from rounds')->array->[0];
    $sleep = time > $round_start ? 0 : $round_start - time;
  }

  Mojo::IOLoop->timer(
    $sleep => sub {
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

  my $db    = $app->pg->db;
  my $round = $db->query('insert into rounds default values returning n')->hash->{n};
  $self->round($round);
  $app->log->debug("Start new round #$round");

  $app->minion->enqueue($_) for (qw/sla flag_points/);

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
      my $old_flag = c(@{$flags->{$team->{id}}{$vuln_id}})->shuffle->first;
      my $id       = $app->minion->enqueue(
        check => [$round, $team, $service, $flag, $old_flag, {n => $n, id => $vuln_id}],
        {queue => 'checker'}
      );
      push @$ids, $id;
      $app->log->debug("Enqueue new job for $team->{name}/$service->{name}/$n: $id");
    }
  }

  return $ids;
}

sub skip_check {
  my ($self, $info) = @_;

  eval {
    $self->app->pg->db->query(
      'insert into runs (round, team_id, service_id, vuln_id, status, result) values (?, ?, ?, ?, ?, ?)',
      $info->{round},
      $info->{team_id},
      $info->{service_id},
      $info->{vuln_id},
      104,
      {json => {error => 'Checker did not run, connect on port was failed.'}}
    );
  };
  $self->app->log->error("Error while insert check result: $@") if $@;
}

sub finalize_check {
  my ($self, $job) = @_;
  my $app = $self->app;

  my $result = $job->info->{result};
  my ($round, $team, $service, $flag, undef, $vuln) = @{$job->args};
  my ($stdout, $status) = ('');

  if (!$result->{check} || $round != $self->round) {
    $result->{error} = 'Job is too old!';
    $status = 104;
  } else {
    my $state = c(qw/get_2 get_1 put check/)->first(sub { defined $result->{$_}{exit_code} });
    $status = $result->{$state}{exit_code};
    $stdout = $result->{$state}{stdout} if $status != 101;
  }

  # Save result
  eval {
    $app->pg->db->query(
      'insert into runs (round, team_id, service_id, vuln_id, status, result, stdout)
      values (?, ?, ?, ?, ?, ?, ?)', $round, $team->{id}, $service->{id}, $vuln->{id}, $status,
      {json => $result}, $stdout
    );
  };
  $app->log->error("Error while insert check result: $@") if $@;

  # Check, put and get was ok, save flag
  return unless ($result->{get_1}{exit_code} // 0) == 101;
  my $id = $result->{put}{fid} // $flag->{id};
  eval {
    $app->pg->db->query(
      'insert into flags (data, id, round, team_id, service_id, vuln_id) values (?, ?, ?, ?, ?, ?)',
      $flag->{data}, $id, $round, $team->{id}, $service->{id}, $vuln->{id});
  };
  $app->log->error("Error while insert flag: $@") if $@;
}

1;
