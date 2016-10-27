package CS::Model::Checker;
use Mojo::Base 'MojoX::Model';

use File::Spec;
use IPC::Run qw/start timeout/;
use List::Util 'all';
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

  return $self->_finish($job, $result)
    unless $round == $job->app->pg->db->query('select max(n) from rounds')->array->[0];

  my $host = $team->{host};
  if (my $cb = $job->app->config->{cs}{checkers}{hostname}) { $host = $cb->($team, $service) }

  # Check
  my $cmd = [$service->{path}, 'check', $host];
  $result->{check} = $self->_run($cmd, $service->{timeout});
  return $self->_finish($job, $result) unless $result->{check}{exit_code} == 101;

  # Put
  $cmd = [$service->{path}, 'put', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{put} = $self->_run($cmd, $service->{timeout});
  (my $id = $result->{put}{stdout}) =~ s/\r?\n$//;
  $flag->{id} = $result->{put}{fid} = $id if $id;
  return $self->_finish($job, $result) unless $result->{put}{exit_code} == 101;

  # Get 1
  $cmd = [$service->{path}, 'get', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{get_1} = $self->_run($cmd, $service->{timeout});
  return $self->_finish($job, $result) unless $result->{get_1}{exit_code} == 101;

  # Get 2
  if ($old_flag) {
    $cmd = [$service->{path}, 'get', $host, $old_flag->{id}, $old_flag->{data}, $vuln->{n}];
    $result->{get_2} = $self->_run($cmd, $service->{timeout});
  }
  return $self->_finish($job, $result);
}

sub _finish {
  my ($self, $job, $result) = @_;
  my $app = $job->app;
  my $db  = $app->pg->db;

  $job->finish($result);

  my ($round, $team, $service, $flag, undef, $vuln) = @{$job->args};
  my ($stdout, $status) = ('');

  if (!$result->{check} || $round != $db->query('select max(n) from rounds')->array->[0]) {
    $result->{error} = 'Job is too old!';
    $status = 104;
  } else {
    my $state = c(qw/get_2 get_1 put check/)->first(sub { defined $result->{$_}{exit_code} });
    $status = $result->{$state}{exit_code};
    $stdout = $result->{$state}{stdout} if $status != 101;
  }

  # Save result
  eval {
    $db->query(
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
    $db->query('insert into flags (data, id, round, team_id, service_id, vuln_id) values (?, ?, ?, ?, ?, ?)',
      $flag->{data}, $id, $round, $team->{id}, $service->{id}, $vuln->{id});
  };
  $app->log->error("Error while insert flag: $@") if $@;
}

sub _run {
  my ($self, $cmd, $timeout) = @_;
  my ($stdout, $stderr);

  my $path = File::Spec->rel2abs($cmd->[0]);
  my (undef, $cwd) = File::Spec->splitpath($path);
  $cmd->[0] = $path;

  $self->app->log->debug("Run '@$cmd' with timeout $timeout");
  my $start = [gettimeofday];
  my $h;
  eval {
    $h = start $cmd, \undef, \$stdout, \$stderr,
      init => sub { chdir $cwd },
      timeout($timeout);
    $h->finish;
  };
  my $elapsed = tv_interval($start);
  if ($@ && $@ =~ /timeout/i) {
    $timeout = 1;
    my $pid = $h->{KIDS}[0]{PID};
    my $n = killfam 9, $pid;
    $self->app->log->debug("Kill all sub process for $pid => $n");
  } else {
    $timeout = 0;
  }

  my $exit = {value => $?, code => $? >> 8, signal => $? & 127, coredump => $? & 128};
  my $code = ($@ || all { $? >> 8 != $_ } (101, 102, 103, 104)) ? 110 : $? >> 8;
  $code = 104 if $timeout;

  return {
    exception => $@,
    timeout   => $timeout,
    stderr    => $stderr,
    stdout    => $stdout,
    exit      => $exit,
    exit_code => $code,
    elapsed   => $elapsed,
    command   => "@$cmd",
    ts        => scalar localtime
  };
}

1;
