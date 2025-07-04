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
use Encode 'decode';

use constant MAX_OUTPUT_LENGTH => 100 * 1024;

# Internal statuses
# 110 -- checker error
# 111 -- service was disabled in this round
has statuses => sub { [[up => 101], [corrupt => 102], [mumble => 103], [down => 104]] };
has status2name => sub {
  return {map { $_->[1] => $_->[0] } @{$_[0]->statuses}};
};

sub info {
  my ($self, $service) = @_;

  my $result = {vulns => {count => 1, distribution => '1'}, public_flag_description => undef};

  my $info = $self->_run([$service->{path}, 'info'], $service->{timeout});
  return $result unless $info->{exit_code} == 101;

  # vulns
  $info->{stdout} =~ /^vulns:(.*)$/m;
  my $vulns = trim($1 // '');
  if ($vulns =~ /^[0-9:]+$/) {
    $result->{vulns}{count} = 0 + split(/:/, $vulns);
    $result->{vulns}{distribution} = $vulns;
  }

  # flag description
  $info->{stdout} =~ /^public_flag_description:(.*)$/m;
  $result->{public_flag_description} = trim($1) if $1;

  return $result;
}

sub check {
  my ($self, $job, $round, $team_id, $service_id, $flag, $old_flag, $vuln) = @_;
  my $result = {vuln => $vuln};
  my $db = $job->app->pg->db;

  my $team    = $db->select('teams', undef, {id => $team_id})->expand->hash;
  my $service = $db->select('services', undef, {id => $service_id})->expand->hash;

  my $cmd;
  my $host = $job->app->model('util')->get_service_host($team, $service);

  for (@{c(qw/check put_get get2/)->shuffle}) {
    my $timeout = min($service->{timeout}, $self->_next_round_start($db, $round));

    if ($_ eq 'check') {
      $cmd = [$service->{path}, 'check', $host];
      $result->{check} = $self->_run($cmd, $timeout);
      return $self->_finish($job, $result, $db) if $result->{check}{slow} || $result->{check}{exit_code} != 101;
    } elsif ($_ eq 'put_get') {
      my $flag_row = {
        data       => $flag->{data},
        id         => $flag->{id},
        round      => $round,
        team_id    => $team_id,
        service_id => $service_id,
        vuln_id    => $vuln->{id}
      };
      $db->insert(flags => $flag_row);

      $cmd = [$service->{path}, 'put', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
      $result->{put} = $self->_run($cmd, $timeout);
      return $self->_finish($job, $result, $db) if $result->{put}{slow} || $result->{put}{exit_code} != 101;

      $flag_row = {ack => 'true'};
      (my $new_id = $result->{put}{stdout}) =~ s/\r?\n$//;
      if ($new_id) {
        $flag_row->{id} = $flag->{id} = $new_id;
        if (my $new_json_id = j($new_id)) {
          $flag_row->{public_id} = $new_json_id->{public_flag_id} if ref $new_json_id eq 'HASH';
        }
      }

      $db->update(flags => $flag_row => {data => $flag->{data}});

      $cmd = [$service->{path}, 'get', $host, $flag->{id}, $flag->{data}, $vuln->{n}];
      $result->{get_1} = $self->_run($cmd, $timeout);
      return $self->_finish($job, $result, $db) if $result->{get_1}{slow} || $result->{get_1}{exit_code} != 101;
    } elsif ($_ eq 'get2') {
      if ($old_flag) {
        $cmd = [$service->{path}, 'get', $host, $old_flag->{id}, $old_flag->{data}, $vuln->{n}];
        $result->{get_2} = $self->_run($cmd, $timeout);
        return $self->_finish($job, $result, $db) if $result->{get_2}{slow} || $result->{get_2}{exit_code} != 101;;
      }
    }
  }

  return $self->_finish($job, $result, $db);
}

sub _finish {
  my ($self, $job, $result, $db) = @_;

  my ($round, $team_id, $service_id, $flag, undef, $vuln) = @{$job->args};
  my ($stdout, $status) = ('');

  # Prepare result for runs
  if (c(qw/get_2 get_1 put check/)->first(sub { defined $result->{$_}{slow} })) {
    $result->{error} = 'Job is too old!';
    $status = 104;
  } else {
    my $state = c(qw/get_2 get_1 put check/)
      ->grep(sub { defined $result->{$_}{exit_code} })
      ->sort(sub { $result->{$a}{exit_code} <=> $result->{$b}{exit_code} })
      ->last;
    $status = $result->{$state}{exit_code};
    $stdout = $result->{$state}{stdout} if $status != 101;
  }

  $job->finish($result);

  my $run = {
    round      => $round,
    team_id    => $team_id,
    service_id => $service_id,
    vuln_id    => $vuln->{id},
    status     => $status,
    result     => decode('UTF-8', j($result)),
    stdout     => $stdout
  };
  $db->insert(runs => $run);
}

sub _next_round_start {
  my ($self, $db, $round) = @_;

  return $db->query('select extract(epoch from ts + ?::interval - now()) from rounds where n = ?',
    $self->app->round_length, $round)->array->[0];
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
  $stdout //= '';
  $stdout =~ s/\x00//g;

  if (length $stdout > MAX_OUTPUT_LENGTH) {
    $self->app->log->warn("Length of STDOUT for '@$cmd' exceeds limit");
    $stdout = substr($stdout, 0, MAX_OUTPUT_LENGTH) . "...";
  }

  my $result = {
    command   => "@$cmd",
    elapsed   => tv_interval($start),
    exception => $@,
    exit      => {value => $?, code => $? >> 8, signal => $? & 127, coredump => $? & 128},
    stderr => decode('UTF-8', ($stderr // '') =~ s/\x00//gr),
    stdout => decode('UTF-8', $stdout),
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

1;
