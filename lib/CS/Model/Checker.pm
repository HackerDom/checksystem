package CS::Model::Checker;
use Mojo::Base 'MojoX::Model';

use Graphics::Color::RGB;
use IPC::Run qw/run timeout/;
use List::Util 'all';
use Time::HiRes qw/gettimeofday tv_interval/;

sub status2color {
  my ($self, $code) = @_;

  return Graphics::Color::RGB->from_hex_string('#FFFFFF') unless $code;

  if ($code == 101) { return Graphics::Color::RGB->from_hex_string('#00DC00') }
  if ($code == 102) { return Graphics::Color::RGB->from_hex_string('#FFFF00') }
  if ($code == 103) { return Graphics::Color::RGB->from_hex_string('#FFA600') }
  if ($code == 104) { return Graphics::Color::RGB->from_hex_string('#E60000') }
  return Graphics::Color::RGB->from_hex_string('#FFFFFF');
}

sub check {
  my ($self, $job, $round, $team, $service, $flag, $old_flag) = @_;
  my $result = {};

  return $self->_finish($job, $result)
    unless $round == $job->app->pg->db->query('select max(n) from rounds')->array->[0];

  # Check
  my $cmd = [$service->{path}, 'check', $team->{host}];
  $result->{check} = $self->_run($cmd, $service->{timeout});
  return $self->_finish($job, $result) unless ($result->{check}{exit_code} == 101);

  # Put
  $cmd = [$service->{path}, 'put', $team->{host}, $flag->{id}, $flag->{data}];
  $result->{put} = $self->_run($cmd, $service->{timeout});
  (my $id = $result->{put}{stdout}) =~ s/\r?\n$//;
  $flag->{id} = $result->{put}{fid} = $id if $id;
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
    command   => "@$cmd"
  };
}

1;
