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

sub game_status {
  my ($self, $now) = @_;

  $now //= localtime;
  my $time = $self->app->config->{cs}{time};
  my ($start, $end) = map { 0 + localtime(Time::Piece->strptime($time->{$_}, $self->format)) } qw/start end/;
  my @break = map { 0 + localtime(Time::Piece->strptime($time->{break}[$_], $self->format)) } 0 .. 1;

  return 0 if $now < $start;
  return 1 if $now >= $start && $now < $break[0];
  return 0 if $now >= $break[0] && $now < $break[1];
  return 1 if $now >= $break[1] && $now < $end;
  return -1;
}

sub progress {
  my $self = shift;

  my $time = $self->app->config->{cs}{time};
  my ($start, $end) = map { 0 + localtime(Time::Piece->strptime($time->{$_}, $self->format)) } qw/start end/;
  my @break = map { 0 + localtime(Time::Piece->strptime($time->{break}[$_], $self->format)) } 0 .. 1;

  my $now = localtime;
  my $all = ($end - $start)->seconds;
  my $p1  = min(($now - $start)->seconds, ($break[0] - $start)->seconds) / $all;
  my $p2  = min(($now - $break[0])->seconds, ($break[1] - $break[0])->seconds) / $all;
  my $p3  = min(($now - $break[1])->seconds, ($end - $break[1])->seconds) / $all;
  for ($p1, $p2, $p3) {
    $_ = 0 if $_ < 0;
    $_ = sprintf '%.2f', $_ * 100;
  }
  $p3 -= $_ if ($_ = $p1 + $p2 + $p3 - 100) > 0;
  return [$p1, $p2, $p3];
}

1;
