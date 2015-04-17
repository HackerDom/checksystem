package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  my $c = shift;

  my ($round, $scoreboard) = $c->model('scoreboard')->generate;
  $c->render(scoreboard => $scoreboard, round => $round);
}

1;
