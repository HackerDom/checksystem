package CS::Model::Flag;
use Mojo::Base 'MojoX::Model';

use String::Random 'random_regex';

my $format = '[A-Z0-9]{31}=';

sub create {
  return {id => join('-', map random_regex('[a-z0-9]{4}'), 1 .. 3), data => random_regex($format)};
}

sub accept {
  my ($self, $team_id, $flag_data, $scoreboard_info, $cb) = @_;

  # return $cb->({ok => 1, message => 'test'});

  my $app = $self->app;
  my $pg  = $app->pg;

  Mojo::IOLoop->delay(
    sub {
      $pg->db->query('select team_id, service_id, round from flags where data = ?', $flag_data, shift->begin);
    },
    sub {
      my ($delay, undef, $result) = @_;

      my $flag = $result->hash;
      return $cb->({ok => 0, error => 'Denied: no such flag'}) unless $flag;
      return $cb->({ok => 0, error => 'Denied: flag is your own'}) if $flag->{team_id} == $team_id;

      $delay->data(flag => $flag);
      $pg->db->query('select * from stolen_flags where data = ? and team_id = ?',
        $flag_data, $team_id, $delay->begin);
    },
    sub {
      my ($delay, undef, $result) = @_;

      return $cb->({ok => 0, error => 'Denied: you already submitted this flag'}) if $result->rows;

      $pg->db->query('select max(n) from rounds', $delay->begin);
    },
    sub {
      my ($delay, undef, $result) = @_;

      return $cb->({ok => 0, error => 'Denied: flag is too old'})
        if $delay->data('flag')->{round} <= $result->array->[0] - $app->config->{cs}{flag_life_time};

      $pg->db->query('insert into stolen_flags (data, team_id) values (?, ?) returning round',
        $flag_data, $team_id, $delay->begin);
    },
    sub {
      my ($delay, undef, $result) = @_;

      return $cb->({ok => 0, error => 'Please try again later'}) unless $result->rows;

      my $amount = $self->amount($scoreboard_info->{scoreboard}, $delay->data('flag')->{team_id}, $team_id);
      my $msg = "Accepted. $flag_data cost $amount flag points";
      $msg .= ' about' if $result->hash->{round} != $scoreboard_info->{round} + 1;
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
