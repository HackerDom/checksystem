package CS::Model::Scoreboard;
use Mojo::Base 'MojoX::Model';

use Graphics::Color::HSV;
use List::Util 'max';

sub generate {
  my $self = shift;
  my $db   = $self->app->pg->db;

  my $scoreboard = $db->query('select * from scoreboard')->expand->hashes;
  my $round = $db->query('select max(n) from rounds')->array->[0] // 0;

  # Calculate score for each service
  my $services;
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
        if ($s->{status} == 110) {
          $s->{bgcolor} = '#ffffff';
          next;
        }
        my $rate = $services->{$s->{id}}{max} == 0 ? 1 : ($s->{sla} * $s->{fp} / $services->{$s->{id}}{max});
        my $nc = Graphics::Color::HSV->new({h => $c->h, s => 0.5 + $c->s * 0.5 * $rate, v => $c->v})->to_rgb;
        $s->{bgcolor} = $nc->as_css_hex;
      }
    }
  );

  return ($round, $scoreboard, $self->app->model('util')->progress);
}

1;
