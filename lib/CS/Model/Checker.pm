package CS::Model::Checker;
use Mojo::Base 'MojoX::Model';

use IPC::Run qw/start timeout/;
use List::Util qw/all min/;
use Mojo::Collection 'c';
use Mojo::File 'path';
use Mojo::JSON 'j';
use Mojo::Util qw/dumper trim/;
use Proc::Killfam;
use Time::HiRes qw/gettimeofday tv_interval/;

# Internal statuses
# 110 -- checker error
# 111 -- service was disabled in this round
has statuses => sub { [[up => 101], [corrupt => 102], [mumble => 103], [down => 104]] };
has status2name => sub {
  return {map { $_->[1] => $_->[0] } @{$_[0]->statuses}};
};

sub vulns {
  my ($self, $service) = @_;

  my $info = $self->_run([$service->{path}, 'info'], $service->{timeout});
  return (1, '1') unless $info->{exit_code} == 101;

  $info->{stdout} =~ /^vulns:(.*)$/m;
  my $vulns = trim($1 // '');
  return (1, '1') unless $vulns =~ /^[0-9:]+$/;

  return (0 + split(/:/, $vulns), $vulns);
}

sub check {
  my ($self, $job, $round, $team, $service, $flag, $old_flag, $vuln) = @_;
  my $result = {vuln => $vuln};
  my $db = $job->app->pg->db;

  if (my $bot_info = $job->app->bots->{$team->{id}}) {
    my $bot = $bot_info->{$service->{id}} // {sla => 0, attack => 1, defense => 0};
    my $r = $self->_run_bot($db, $bot, $team, $service, $flag, $vuln, $round);
    return $self->_finish($job, {%$result, %$r}, $db);
  }

  my $host = $team->{host};
  if (my $cb = $job->app->config->{cs}{checkers}{hostname}) { $host = $cb->($team, $service) }

  # Check
  my $cmd = [$service->{path}, 'check', $host];
  $result->{check} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  return $self->_finish($job, $result, $db) if $result->{check}{slow} || $result->{check}{exit_code} != 101;

  my $flag_row = {
    data       => $flag->{data},
    id         => $flag->{id},
    round      => $round,
    team_id    => $team->{id},
    service_id => $service->{id},
    vuln_id    => $vuln->{id}
  };
  $db->insert(flags => $flag_row);

  # Put
  $cmd = [$service->{path}, 'put', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{put} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  return $self->_finish($job, $result, $db) if $result->{put}{slow} || $result->{put}{exit_code} != 101;

  $flag_row = {ack => 'true'};
  (my $id = $result->{put}{stdout}) =~ s/\r?\n$//;
  $flag_row->{id} = $flag->{id} = $result->{put}{fid} = $id if $id;
  $db->update(flags => $flag_row => {data => $flag->{data}});

  # Get 1
  $cmd = [$service->{path}, 'get', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{get_1} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  return $self->_finish($job, $result, $db) if $result->{get_1}{slow} || $result->{get_1}{exit_code} != 101;

  # Get 2
  if ($old_flag) {
    $cmd = [$service->{path}, 'get', $host, $old_flag->{id}, $old_flag->{data}, $vuln->{n}];
    $result->{get_2} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  }
  return $self->_finish($job, $result, $db);
}

sub _finish {
  my ($self, $job, $result, $db) = @_;

  my ($round, $team, $service, $flag, undef, $vuln) = @{$job->args};
  my ($stdout, $status) = ('');

  # Prepare result for runs
  if (c(qw/get_2 get_1 put check/)->first(sub { defined $result->{$_}{slow} })) {
    $result->{error} = 'Job is too old!';
    $status = 104;
  } else {
    my $state = c(qw/get_2 get_1 put check/)->first(sub { defined $result->{$_}{exit_code} });
    $status = $result->{$state}{exit_code};
    $stdout = $result->{$state}{stdout} if $status != 101;
  }

  $job->finish($result);

  # Check changes
  my $res = $db->select('runs', 'status',
    {round => $round - 1, service_id => $service->{id}, team_id => $team->{id}});
  if ($res->rows && $round > 1) {
    my $old_status = $res->hash->{status};
    if ($old_status != $status) {
      my $data = {
        round      => $round,
        team_id    => $team->{id},
        service_id => $service->{id},
        status     => $status,
        old_status => $old_status
      };
      $self->app->pg->pubsub->json('service_status_changed')->notify(service_status_changed => $data);
    }
  }

  my $run = {
    round      => $round,
    team_id    => $team->{id},
    service_id => $service->{id},
    vuln_id    => $vuln->{id},
    status     => $status,
    result     => j($result),
    stdout     => $stdout
  };
  $db->insert(runs => $run);
}

sub _next_round_start {
  my ($self, $db, $round) = @_;

  return $db->query('select extract(epoch from ts + ?::interval - now()) from rounds where n = ?',
    $self->app->config->{cs}{round_length}, $round)->array->[0];
}

sub _run {
  my ($self, $cmd, $timeout) = @_;
  my ($stdout, $stderr);

  return {slow => 1} if $timeout <= 0;

  my $path = path($cmd->[0])->to_abs;
  $cmd->[0] = $path->to_string;

  $self->app->log->debug("Run '@$cmd' with timeout $timeout");
  my ($t, $h) = timeout($timeout);
  my $start = [gettimeofday];
  eval {
    $h = start $cmd, \undef, \$stdout, \$stderr, 'init', sub { chdir $path->dirname }, $t;
    $h->finish;
  };
  my $result = {
    command   => "@$cmd",
    elapsed   => tv_interval($start),
    exception => $@,
    exit      => {value => $?, code => $? >> 8, signal => $? & 127, coredump => $? & 128},
    stderr => ($stderr // '') =~ s/\x00//gr,
    stdout => ($stdout // '') =~ s/\x00//gr,
    timeout => 0
  };
  $result->{exit_code} = ($@ || all { $? >> 8 != $_ } (101, 102, 103, 104)) ? 110 : $? >> 8;

  if ($@ && $@ =~ /timeout/i) {
    $result->{timeout}   = 1;
    $result->{exit_code} = 104;
    my $pid = $h->{KIDS}[0]{PID};
    my $n = killfam 9, $pid;
    $self->app->log->debug("Kill all sub process for $pid => $n");
  }

  $result->{ts} = scalar(localtime);
  return $result;
}

sub _run_bot {
  my ($self, $db, $bot, $team, $service, $flag, $vuln, $round) = @_;
  my $app    = $self->app;
  my $result = {};

  my $exit_code = rand() < $bot->{sla} ? 101 : 104;
  for my $command (qw/check put get_1 get_2/) {
    $result->{$command} = {
      command   => dumper($bot),
      elapsed   => 0,
      exception => undef,
      exit      => {value => 0, code => 0, signal => 0, coredump => 0},
      stderr    => '',
      stdout    => '',
      timeout   => 0,
      ts        => scalar(localtime),
      exit_code => $exit_code
    };
  }
  return $result unless $exit_code == 101;
  my $flag_row = {
    data       => $flag->{data},
    id         => $flag->{id},
    round      => $round,
    team_id    => $team->{id},
    service_id => $service->{id},
    vuln_id    => $vuln->{id},
    ack        => 'true'
  };
  $db->insert(flags => $flag_row);

  my $game_time = $app->model('util')->game_time;
  my $now       = time;
  my $current   = ($now - $game_time->{start}) / ($game_time->{end} - $game_time->{start});
  return $result unless $bot->{attack} < $current;

  # Hack
  my $flags = $db->query(
    'select data from flags where service_id = $1 and round between $3 - 3 and $3 and team_id in
      (select team_id from bots where service_id = $1 and team_id != $2 and defense > $4)', $service->{id},
    $team->{id}, $round, $current
  )->arrays;
  for my $flag (@$flags) {
    $app->model('flag')->accept($team->{id}, $flag->[0], sub { });
  }

  return $result;
}

1;
