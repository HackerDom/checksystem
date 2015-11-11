package CS::Model::Checker;
use Mojo::Base 'MojoX::Model';

use Convert::Color;
use IPC::Run qw/run timeout/;
use List::Util 'all';
use Mojo::Util 'trim';
use Time::HiRes qw/gettimeofday tv_interval/;

has statuses => sub {
  [ [UP      => $_[0]->status2color(101)->hex],
    [CORRUPT => $_[0]->status2color(102)->hex],
    [MUMBLE  => $_[0]->status2color(103)->hex],
    [DOWN    => $_[0]->status2color(104)->hex]
  ];
};

sub status2color {
  my ($self, $code) = @_;

  return Convert::Color->new('rgb8:ffffff') unless $code;

  if ($code == 101) { return Convert::Color->new('rgb8:00dc00') }
  if ($code == 102) { return Convert::Color->new('rgb8:ffff00') }
  if ($code == 103) { return Convert::Color->new('rgb8:ffa600') }
  if ($code == 104) { return Convert::Color->new('rgb8:e60000') }
  return Convert::Color->new('rgb8:ffffff');
}

sub vulns {
  my ($self, $service) = @_;

  my $info = $self->_run([$service->{path}, 'info'], $service->{timeout});
  return (1, '1') unless $info->{exit_code} == 101;

  $info->{stdout} =~ /^vulns:(.*)$/m;
  my $vulns = trim $1;
  return (1, '1') unless $vulns =~ /^[0-9:]+$/;

  return (0 + split(/:/, $vulns), $vulns);
}

sub check {
  my ($self, $job, $round, $team, $service, $flag, $old_flag, $vuln) = @_;
  my $result = {};

  return $self->_finish($job, $result)
    unless $round == $job->app->pg->db->query('select max(n) from rounds')->array->[0];

  # Check
  my $cmd = [$service->{path}, 'check', $team->{host}];
  $result->{check} = $self->_run($cmd, $service->{timeout});
  return $self->_finish($job, $result) unless $result->{check}{exit_code} == 101;

  # Put
  $cmd = [$service->{path}, 'put', $team->{host}, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{put} = $self->_run($cmd, $service->{timeout});
  (my $id = $result->{put}{stdout}) =~ s/\r?\n$//;
  $flag->{id} = $result->{put}{fid} = $id if $id;
  return $self->_finish($job, $result) unless $result->{put}{exit_code} == 101;

  # Get 1
  $cmd = [$service->{path}, 'get', $team->{host}, $flag->{id}, $flag->{data}, $vuln->{n}];
  $result->{get_1} = $self->_run($cmd, $service->{timeout});
  return $self->_finish($job, $result) unless $result->{get_1}{exit_code} == 101;

  # Get 2
  if ($old_flag) {
    $cmd = [$service->{path}, 'get', $team->{host}, $old_flag->{id}, $old_flag->{data}, $vuln->{n}];
    $result->{get_2} = $self->_run($cmd, $service->{timeout});
  }
  return $self->_finish($job, $result);
}

sub _finish {
  my ($self, $job, $result) = @_;

  $job->finish($result);
  $job->app->pg->pubsub->notify(job_finish => $job->id);
}

sub _run {
  my ($self, $cmd, $timeout) = @_;
  my ($stdout, $stderr);

  $self->app->log->debug("Run '@$cmd' with timeout $timeout");
  my $start = [gettimeofday];
  eval { run $cmd, \undef, \$stdout, \$stderr, timeout($timeout) };
  my $elapsed = tv_interval($start);

  $timeout = ($@ && $@ =~ /timeout/i) ? 1 : 0;
  my $code = ($@ || all { $? >> 8 != $_ } (101, 102, 103, 104)) ? 110 : $? >> 8;
  $code = 104 if $timeout;

  return {
    exception => $@,
    timeout   => $timeout,
    stderr    => $stderr,
    stdout    => $stdout,
    exit_code => $code,
    elapsed   => $elapsed,
    command   => "@$cmd",
    ts        => scalar localtime
  };
}

1;
