package CS::Command::manager;
use Mojo::Base 'Mojolicious::Command';

use List::Util 'first';

has description => 'Run CTF game.';

has teams    => sub { {} };
has services => sub { {} };
has round    => 0;

sub run {
  my $self = shift;
  my $app  = $self->app;

  $self->init;

  $app->pg->pubsub->listen(
    job_finish => sub {
      my ($pubsub, $job_id) = @_;
      my $job = $app->minion->job($job_id);
      return if $job->args->[0] != $self->round;

      $self->finalize_check($job);
    }
  );

  Mojo::IOLoop->next_tick(sub { $self->start_round });
  Mojo::IOLoop->recurring($app->config->{cs}{round_length} => sub { $self->start_round });
  Mojo::IOLoop->start;
}

sub start_round {
  my $self = shift;
  my $app  = $self->app;
  my $ids;

  my $round = $app->pg->db->query('insert into rounds default values returning n')->hash->{n};
  $self->round($round);
  $app->log->debug("Start new round #$round");

  for my $team (values %{$self->teams}) {
    for my $service (values %{$self->services}) {
      my $flag     = $app->model('flag')->create;
      my $old_flag = $app->pg->db->query(
        "select id, data from flags
        where team_id = ? and service_id = ? and ts >= (now() - (interval '1 second' * ?))
        order by random() limit 1" => ($team->{id}, $service->{id}, $app->config->{cs}{flag_expire_interval})
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

sub init {
  my $self = shift;
  my $app  = $self->app;

  $self->teams(
    $app->pg->db->query('select * from teams')->hashes->reduce(sub { $a->{$b->{id}} = $b; $a }, {}));

  my $services =
    $app->pg->db->query('select * from services')->hashes->reduce(sub { $a->{$b->{name}} = $b; $a }, {});
  for (@{$app->config->{services}}) {
    my $service = $services->{$_->{name}};
    $self->services->{$service->{id}} = {id => $service->{id}, %$_};
  }

  return $self;
}

1;
