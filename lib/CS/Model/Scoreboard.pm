package CS::Model::Scoreboard;
use Mojo::Base 'MojoX::Model';

use Graphics::Color::HSV;
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
        my $c = $self->app->model('checker')->status2color($s->{status})->to_hsv;
        if ($c->to_rgb->equal_to(Graphics::Color::RGB->from_hex_string('#FFFFFF'))) {
          $s->{bgcolor} = $c->to_rgb->as_css_hex;
          next;
        }
        my $rate = $services->{$s->{id}}{max} == 0 ? 1 : ($s->{sla} * $s->{fp} / $services->{$s->{id}}{max});
        my $nc = Graphics::Color::HSV->new({h => $c->h, s => 0.5 + $c->s * 0.5 * $rate, v => $c->v})->to_rgb;
        $s->{bgcolor} = $nc->as_css_hex;
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
