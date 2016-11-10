package CS::Model::Checker;
use Mojo::Base 'MojoX::Model';

use File::Spec;
use IPC::Run qw/start timeout/;
use List::Util qw/all min/;
use Mojo::Collection 'c';
use Mojo::Util 'trim';
use Proc::Killfam;
use Time::HiRes qw/gettimeofday tv_interval/;

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

  my $host = $team->{host};
  if (my $cb = $job->app->config->{cs}{checkers}{hostname}) { $host = $cb->($team, $service) }

  # Check
  my $cmd = [$service->{path}, 'check', $host];
  $result->{check} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  return $self->_finish($job, $result, $db) if $result->{slow} || $result->{check}{exit_code} != 101;

  # Put
  $cmd = [$service->{path}, 'put', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{put} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  return $self->_finish($job, $result, $db) if $result->{slow} || $result->{put}{exit_code} != 101;
  (my $id = $result->{put}{stdout}) =~ s/\r?\n$//;
  $flag->{id} = $result->{put}{fid} = $id if $id;

  # Get 1
  $cmd = [$service->{path}, 'get', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{get_1} = $self->_run($cmd, min($service->{timeout}, $self->_next_round_start($db, $round)));
  return $self->_finish($job, $result, $db) if $result->{slow} || $result->{get_1}{exit_code} != 101;

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
  if ($result->{slow}) {
    $result->{error} = 'Job is too old!';
    $status = 104;
  }
  else {
    my $state = c(qw/get_2 get_1 put check/)->first(sub { defined $result->{$_}{exit_code} });
    $status = $result->{$state}{exit_code};
    $stdout = $result->{$state}{stdout} if $status != 101;
  }

  $job->finish($result);
  $self->app->metric->write('check', 1,
    {status => $status, team => $team->{id}, service => $service->{id}, vuln => $vuln->{id}, round => $round}
  );

  # Save result
  eval {
    $db->query(
      'insert into runs (round, team_id, service_id, vuln_id, status, result, stdout)
      values (?, ?, ?, ?, ?, ?, ?)', $round, $team->{id}, $service->{id}, $vuln->{id}, $status,
      {json => $result}, $stdout
    );
  };
  $self->app->log->error("Error while insert check result: $@") if $@;

  # Check, put and get was ok, save flag
  return unless ($result->{get_1}{exit_code} // 0) == 101;
  my $id = $result->{put}{fid} // $flag->{id};
  eval {
    $db->query('insert into flags (data, id, round, team_id, service_id, vuln_id) values (?, ?, ?, ?, ?, ?)',
      $flag->{data}, $id, $round, $team->{id}, $service->{id}, $vuln->{id});
  };
  $self->app->log->error("Error while insert flag: $@") if $@;
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

  my $path = File::Spec->rel2abs($cmd->[0]);
  my (undef, $cwd) = File::Spec->splitpath($path);
  $cmd->[0] = $path;

  $self->app->log->debug("Run '@$cmd' with timeout $timeout");
  my ($t, $h) = timeout($timeout);
  my $start = [gettimeofday];
  eval {
    $h = start $cmd, \undef, \$stdout, \$stderr, 'init', sub { chdir $cwd }, $t;
    $h->finish;
  };
  my $result = {
    command   => "@$cmd",
    elapsed   => tv_interval($start),
    exception => $@,
    exit      => {value => $?, code => $? >> 8, signal => $? & 127, coredump => $? & 128},
    stderr    => $stderr =~ s/\x00//gr,
    stdout    => $stdout =~ s/\x00//gr,
    timeout   => 0
  };
  $result->{exit_code} = ($@ || all { $? >> 8 != $_ } (101, 102, 103, 104)) ? 110 : $? >> 8;

  if ($@ && $@ =~ /timeout/i) {
    $result->{timeout}   = 1;
    $result->{exit_code} = 104;
    my $pid = $h->{KIDS}[0]{PID};
    my $n = killfam 9, $pid;
    $self->app->log->debug("Kill all sub process for $pid => $n");
  }

  $result->{ts} = scalar localtime;
  return $result;
}

1;
