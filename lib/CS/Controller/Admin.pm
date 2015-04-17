package CS::Controller::Admin;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  my $c = shift;

  my ($round, $scoreboard) = $c->model('scoreboard')->generate;
  $c->render(scoreboard => $scoreboard, round => $round);
}

sub view {
  my $c = shift;

  my $db     = $c->pg->db;
  my $view = $db->query(
    'select round, status, result from runs where team_id = ? and service_id = ? order by round desc',
    $c->param('team_id'),
    $c->param('service_id')
  )->expand->hashes->to_array;
  $c->render(view => $view);
}

1;
