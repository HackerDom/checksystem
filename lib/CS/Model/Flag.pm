package CS::Model::Flag;
use Mojo::Base 'MojoX::Model';

use Digest::SHA 'hmac_sha1_hex';
use String::Random 'random_regex';
use Time::HiRes 'time';

my $format = '[A-Z0-9]{31}=';

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
        return $cb->({ok => 0, error => "[$flag_data] $msg"});
      }

      my $data = {round => $round, service_id => $service_id, team_id => $team_id, victim_id => $victim_id};
      $app->pg->pubsub->json('flag')->notify(flag => $data);

      $msg = "[$flag_data] Accepted. $amount flag points";
      return $cb->({ok => 1, message => $msg});
    }
    )->catch(
    sub {
      $app->log->error("[flags] Error while accept: $_[0]");
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

1;
