package CS::Controller::Admin;
use Mojo::Base 'Mojolicious::Controller';

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub view {
  my $c = shift;

  my $db   = $c->pg->db;
  my $view = $db->query(
    'select round, status, result
    from runs where team_id = ? and service_id = ? order by round desc limit 30', $c->param('team_id'),
    $c->param('service_id')
  )->expand->hashes->to_array;
  $c->render(view => $view);
}

1;
