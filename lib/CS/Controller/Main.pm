package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  my $c = shift;

  my ($round, $scoreboard, $progress) = $c->model('scoreboard')->generate;
  $c->render(scoreboard => $scoreboard, round => $round, progress => $progress);
}

1;
