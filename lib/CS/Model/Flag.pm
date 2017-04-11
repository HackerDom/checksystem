package CS::Model::Flag;
use Mojo::Base 'MojoX::Model';

use Digest::SHA 'hmac_sha1_hex';
use String::Random 'random_regex';

my $format = '[A-Z0-9]{31}=';

sub create {
  my $self = shift;

  my $id   = join('-', map random_regex('[a-z0-9]{4}'), 1 .. 3);
  my $data = random_regex('[A-Z0-9]{21}');
  my $sign = uc substr hmac_sha1_hex($data, $self->app->config->{cs}{flags}{secret}), 0, 10;

  return {id => $id, data => "${data}${sign}="};
}

sub accept {
  my ($self, $team_id, $flag_data, $scoreboard_info, $cb) = @_;
  my $app = $self->app;
  my @metric = ('flags', {data => $flag_data}, {team => $team_id});

  Mojo::IOLoop->delay(
    sub {
      unless ($self->validate($flag_data)) {
        $metric[2]{state} = 'invalid';
        $app->metric->write(@metric);
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
      my ($ok, $msg, $round, $victim_id, $service_id) = @{$result->expand->hash->{r}}{qw/f1 f2 f3 f4 f5/};

      unless ($ok) {
        $metric[2]{state} = 'reject';
        $app->metric->write(@metric);
        return $cb->({ok => 0, error => "[$flag_data] $msg"});
      }

      $metric[2]{state} = 'accept';
      $app->metric->write(@metric);

      my $amount = $self->amount($scoreboard_info->{scoreboard}, $victim_id, $team_id);
      $msg = "[$flag_data] Accepted. About $amount flag points";

      my $data = {round => $round, service_id => $service_id, team_id => $team_id, victim_id => $victim_id};
      $app->pg->pubsub->json('flag')->notify(flag => $data);

      return $cb->({ok => 1, message => $msg});
    }
    )->catch(
    sub {
      $app->log->error("[flags] Error while accept: $_[1]");
      $metric[2]{state} = 'error';
      $app->metric->write(@metric);
      return $cb->({ok => 0, error => 'Please try again later'});
    }
    )->wait;
}

sub amount {
  my ($self, $scoreboard, $victim_id, $team_id) = @_;

  my $jackpot = 0 + keys %{$self->app->teams};
  my ($v, $t) = @{$scoreboard}{$victim_id, $team_id};

  return $t >= $v ? $jackpot : exp(log($jackpot) * ($v - $jackpot) / ($t - $jackpot));
}

sub validate {
  my ($self, $flag) = @_;

  return undef unless $flag =~ /^$format$/;
  my $data = substr $flag, 0, 21;
  my $sign = uc substr hmac_sha1_hex($data, $self->app->config->{cs}{flags}{secret}), 0, 10;
  return $sign eq substr $flag, 21, 10;
}

1;
