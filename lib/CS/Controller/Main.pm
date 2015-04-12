package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  my $c = shift;

  $c->render(scoreboard => $c->pg->db->query('select * from scoreboard')->expand->hashes);
}

1;
