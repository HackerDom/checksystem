package CS::Model::Scoreboard;
use Mojo::Base 'MojoX::Model';

use List::Util 'first';

sub generate {
  my $self = shift;
  my $db   = $self->app->pg->db;

  my $scoreboard = $db->query('select * from scoreboard order by n')->expand->hashes;

  return (
    {scoreboard => $scoreboard->to_array, round => $db->query('select max(n) from rounds')->array->[0]});
}

1;
