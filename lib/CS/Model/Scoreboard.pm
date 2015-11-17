package CS::Model::Scoreboard;
use Mojo::Base 'MojoX::Model';

use List::Util 'first';

sub generate {
  my $self = shift;
  my $db   = $self->app->pg->db;

  my $scoreboard = $db->query('select * from scoreboard order by n')->expand->hashes;
  $scoreboard->map(
    sub {
      for my $s (@{$_->{services}}) {
        if (($s->{status} // 0) != 101) {
          my $state = first { defined $s->{result}{$_}{exit_code} } (qw/get_2 get_1 put check/);
          $s->{title} = $s->{result}{$state}{stdout} // '' if $state;
        }
        $s->{bgcolor} = '#' . $self->app->model('checker')->status2color($s->{status})->as_rgb8->hex;
      }
    }
  );

  return ({scoreboard => $scoreboard, round => $db->query('select max(n) from rounds')->array->[0]});
}

1;
