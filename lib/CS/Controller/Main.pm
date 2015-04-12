package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  my $c  = shift;
  my $db = $c->pg->db;

  my $scoreboard = $db->query('select * from scoreboard')->expand->hashes;
  my $round = $db->query('select max(n) from rounds')->array->[0] // 0;

  $c->render(scoreboard => $scoreboard, round => $round);
}

1;
