package CS::Command::manager;
use Mojo::Base 'Mojolicious::Command';

use List::Util 'first';
use Time::Piece;
use Time::Seconds;

has description => 'Run CTF game.';

has round => sub { $_[0]->app->pg->db->query('select max(n) from rounds')->array->[0] };

sub run {
  my $self = shift;
  my $app  = $self->app;

  $app->pg->pubsub->listen(
    job_finish => sub {
      my ($pubsub, $job_id) = @_;
      my $job = $app->minion->job($job_id);
      return if $job->args->[0] != $self->round;

      $self->finalize_check($job);
    }
  );

  my $now = localtime;
  my $start = localtime(Time::Piece->strptime($app->config->{cs}{time}{start}, $app->model('util')->format));
  Mojo::IOLoop->timer(
    ($now < $start ? ($start - $now)->seconds : 0) => sub {
      Mojo::IOLoop->recurring($app->config->{cs}{round_length} => sub { $self->start_round });
      $self->start_round;
    }
  );

  Mojo::IOLoop->recurring(15 => sub { $app->minion->enqueue('scoreboard') });
  Mojo::IOLoop->start;
}

sub start_round {
  my $self = shift;
  my ($app, $ids) = ($self->app);

  # Check end of game
  if ($app->model('util')->game_status == -1) {
    $app->minion->enqueue($_ => $self->round) for (qw/sla flag_points/);
  }
  return unless $app->model('util')->game_status == 1;

  $app->minion->enqueue($_) for (qw/sla flag_points/);

  my $round = $app->pg->db->query('insert into rounds default values returning n')->hash->{n};
  $self->round($round);
  $app->log->debug("Start new round #$round");

  for my $team (values %{$app->teams}) {
    for my $service (values %{$app->services}) {
      my $flag     = $app->model('flag')->create;
      my $old_flag = $app->pg->db->query(
        'select id, data from flags
        where team_id = ? and service_id = ? and round >= ? order by random() limit 1',
        ($team->{id}, $service->{id}, $round - $app->config->{cs}{flag_life_time})
      )->hash;
      my $id = $app->minion->enqueue(check => [$round, $team, $service, $flag, $old_flag]);
      push @$ids, $id;
      $app->log->debug("Enqueue new job for $team->{name}/$service->{name}: $id");
    }
  }

  return $ids;
}

sub finalize_check {
  my ($self, $job) = @_;
  my $app = $self->app;

  my $result = $job->info->{result};
  my ($round, $team, $service, $flag) = @{$job->args};

  # Save result
  my $status = first { defined $result->{$_}{exit_code} } (qw/get_2 get_1 put check/);
  eval {
    $app->pg->db->query(
      'insert into runs (round, team_id, service_id, status, result) values (?, ?, ?, ?, ?)',
      $self->round, $team->{id}, $service->{id},
      $result->{$status}{exit_code},
      {json => $result}
    );
  };
  $app->log->error("Error while insert check result: $@") if $@;

  # Check, put and get was ok, save flag
  if (($result->{get_1}{exit_code} // 0) == 101) {
    eval {
      $app->pg->db->query(
        'insert into flags (data, id, round, team_id, service_id) values (?, ?, ?, ?, ?)',
        $flag->{data}, $result->{put}{fid} // $flag->{id},
        $self->round, $team->{id}, $service->{id}
      );
    };
    $app->log->error("Error while insert flag: $@") if $@;
  }
}

1;
