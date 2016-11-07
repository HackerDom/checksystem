package CS::Model::Util;
use Mojo::Base 'MojoX::Model';

use Time::Piece;
use List::Util 'min';

has format => '%Y-%m-%d %H:%M:%S';

sub team_id_by_address {
  my ($self, $address) = @_;

  my $team = $self->app->pg->db->query("select id from teams where ? <<= network", $address)->hash;
  return $team ? $team->{id} : undef;
}

sub game_time {
  my $self = shift;

  my $time = $self->app->config->{cs}{time};
  my ($start, $end) = map { 0 + localtime(Time::Piece->strptime($time->{$_}, $self->format)) } qw/start end/;
  $start += localtime->tzoffset;
  $end   += localtime->tzoffset;
  return {start => $start->epoch, end => $end->epoch};
}

sub game_status {
  my ($self, $now) = @_;

  $now //= localtime;
  my $time = $self->app->config->{cs}{time};
  my ($start, $end) = map { 0 + localtime(Time::Piece->strptime($time->{$_}, $self->format)) } qw/start end/;
  my @break;
  if (my $break = $time->{break}) {
    @break = map { 0 + localtime(Time::Piece->strptime($break->[$_], $self->format)) } 0 .. 1;
  }

  return 0 if $now < $start;
  return 1 if $now >= $start && $now < $break[0];
  return 0 if @break && $now >= $break[0] && $now < $break[1];
  return 1 if $now >= $break[1] && $now < $end;
  return -1;
}

1;
