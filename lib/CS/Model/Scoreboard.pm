package CS::Model::Scoreboard;
use Mojo::Base 'MojoX::Model';

use Convert::Color;
use List::Util 'max';
use Time::Piece;

sub generate {
  my $self = shift;
  my $db   = $self->app->pg->db;

  # Calculate score for each service
  my $services;
  my $scoreboard = $db->query('select * from scoreboard')->expand->hashes;
  $scoreboard->map(
    sub {
      for my $s (@{$_->{services}}) {
        push @{$services->{$s->{id}}{all}}, $s->{sla} * $s->{fp};
      }
    }
  );
  $services->{$_}{max} = max @{$services->{$_}{all}} for keys %$services;
  $scoreboard->map(
    sub {
      for my $s (@{$_->{services}}) {
        my $c = $self->app->model('checker')->status2color($s->{status});
        if ($c->as_rgb8->hex eq 'ffffff') {
          $s->{bgcolor} = '#ffffff';
          next;
        }
        $c = $c->as_hsv;
        my $rate = $services->{$s->{id}}{max} == 0 ? 1 : ($s->{sla} * $s->{fp} / $services->{$s->{id}}{max});
        my $nc = Convert::Color::HSV->new($c->hue, 0.5 + $c->saturation * 0.5 * $rate, $c->value);
        $s->{bgcolor} = '#' . $nc->as_rgb8->hex;
      }
    }
  );

  return (
    { scoreboard => $scoreboard,
      round      => $db->query('select max(n) from rounds')->array->[0],
      progress   => $self->app->model('util')->progress,
      achievement =>
        $db->query("select *, extract(epoch from ts)::int as time from achievement order by ts desc")
        ->hashes->map(sub { $_->{time} = (gmtime() - gmtime($_->{time}))->pretty; $_ })
    }
  );
}

1;
