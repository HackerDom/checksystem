package CS::Model::Flag;
use Mojo::Base 'MojoX::Model';

use Digest::SHA 'hmac_sha1_hex';
use String::Random 'random_regex';
use Time::HiRes 'time';

my $format = '[A-Z0-9]{31}=';

has stats => sub { return {ts => 0} };

sub create {
  my $self = shift;

  my $id   = join('-', map random_regex('[a-z0-9]{4}'), 1 .. 3);
  my $data = random_regex('[A-Z0-9]{21}');
  my $sign = uc substr hmac_sha1_hex($data, $self->app->config->{cs}{flags}{secret}), 0, 10;

  return {id => $id, data => "${data}${sign}="};
}

sub accept {
  my ($self, $team_id, $flag_data, $cb) = @_;
  my $app = $self->app;

  Mojo::IOLoop->delay(
    sub {
      unless ($self->validate($flag_data)) {
        $self->_metric('invalid');
        return $cb->({ok => 0, error => "[$flag_data] Denied: invalid flag"});
      }

      $app->pg->db->query(
        'select row_to_json(accept_flag(?, ?, ?)) as r',
        $team_id, $flag_data, $app->config->{cs}{flag_life_time},
        shift->begin
      );
    },
    sub {
      my ($d, undef, $result) = @_;
      my ($ok, $msg, $round, $victim_id, $service_id, $amount) =
        @{$result->expand->hash->{r}}{qw/f1 f2 f3 f4 f5 f6/};

      unless ($ok) {
        $self->_metric('reject');
        return $cb->({ok => 0, error => "[$flag_data] $msg"});
      }

      my $data = {round => $round, service_id => $service_id, team_id => $team_id, victim_id => $victim_id};
      $app->pg->pubsub->json('flag')->notify(flag => $data);

      $self->_metric('accept');
      $msg = "[$flag_data] Accepted. $amount flag points";
      return $cb->({ok => 1, message => $msg});
    }
    )->catch(
    sub {
      $app->log->error("[flags] Error while accept: $_[0]");
      $self->_metric('error');
      return $cb->({ok => 0, error => 'Please try again later'});
    }
    )->wait;
}

sub validate {
  my ($self, $flag) = @_;

  return undef unless $flag =~ /^$format$/;
  my $data = substr $flag, 0, 21;
  my $sign = uc substr hmac_sha1_hex($data, $self->app->config->{cs}{flags}{secret}), 0, 10;
  return $sign eq substr $flag, 21, 10;
}

sub _metric {
  my ($self, $key) = @_;

  my $stats = $self->stats;
  ++$stats->{$key};

  if ((my $now = time) - $stats->{ts} > 1) {
    for ('accept', 'reject', 'invalid', 'error') {
      $self->app->metric->write("flags.$_", $stats->{$_} // 0, {});
      delete $stats->{$_};
    }
    $stats->{ts} = $now;
  }
}

1;
