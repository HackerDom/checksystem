package CS::Model::Flag;
use Mojo::Base 'MojoX::Model';

use String::Random 'random_regex';

my $format = '[A-Z0-9]{31}=';

sub create {
  return {id => join('-', map random_regex('[a-z0-9]{4}'), 1 .. 3), data => random_regex($format)};
}

sub accept {
  my ($self, $team_id, $flag_data, $scoreboard_info, $cb) = @_;
  my $app = $self->app;

  Mojo::IOLoop->delay(
    sub {
      $app->pg->db->query(
        'select row_to_json(accept_flag(?, ?, ?)) as r',
        $team_id, $flag_data, $app->config->{cs}{flag_life_time},
        shift->begin
      );
    },
    sub {
      my ($d, undef, $result) = @_;
      my ($ok, $msg, $round, $victim_id) = @{$result->expand->hash->{r}}{qw/f1 f2 f3 f4/};

      return $cb->({ok => 0, error => $msg}) unless $ok;

      my $amount = $self->amount($scoreboard_info->{scoreboard}, $victim_id, $team_id);
      $msg = "Accepted. $flag_data cost $amount flag points";
      $msg .= ' about' if $round != $scoreboard_info->{round} + 1;
      return $cb->({ok => 1, message => $msg});
    }
    )->catch(
    sub {
      $app->log->error("[flags] Error while accept: $_[1]");
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

sub validate { $_[1] =~ /^$format$/ }

1;
