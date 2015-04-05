package CS::Model::Checker;
use Mojo::Base 'MojoX::Model';

use IPC::Run qw/run timeout/;
use List::Util 'all';

sub check {
  my ($self, $round, $job, $team, $service, $flag, $old_flag) = @_;
  my $result;

  # Check
  my $cmd = [$service->{path}, 'check', $team->{host}];
  $result->{check} = $self->_run($cmd, $service->{timeout});
  return $self->_finish($job, $result) unless ($result->{check}{exit_code} == 101);

  # Put
  $cmd = [$service->{path}, 'put', $team->{host}, $flag->{id}, $flag->{data}];
  $result->{put} = $self->_run($cmd, $service->{timeout});
  return $self->_finish($job, $result) unless $result->{put}{exit_code} == 101;

  # Get 1
  $cmd = [$service->{path}, 'get', $team->{host}, $flag->{id}, $flag->{data}];
  $result->{get_1} = $self->_run($cmd, $service->{timeout});
  return $self->_finish($job, $result) unless $result->{get_1}{exit_code} == 101;

  # Get 2
  if ($old_flag) {
    $cmd = [$service->{path}, 'get', $team->{host}, $old_flag->{id}, $old_flag->{data}];
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

  eval { run $cmd, \undef, \$stdout, \$stderr, timeout($timeout) };
  my $code = ($@ || all { $? >> 8 != $_ } (101, 102, 103, 104)) ? 110 : $? >> 8;
  return {
    exception => $@,
    timeout   => ($@ && $@ =~ /timeout/i) ? 1 : 0,
    stderr    => $stderr,
    stdout    => $stdout,
    exit_code => $code
  };
}

1;
