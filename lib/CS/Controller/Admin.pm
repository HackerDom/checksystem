package CS::Controller::Admin;
use Mojo::Base 'Mojolicious::Controller';

sub auth {
  my $c = shift;

  return 1 if ($c->req->url->to_abs->userinfo // '') eq $c->config->{cs}{admin}{auth};
  $c->res->headers->www_authenticate('Basic');
  $c->render(text => 'Authentication required!', status => 401);
  return undef;
}

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub view {
  my $c = shift;

  my $db   = $c->pg->db;
  my $view = $db->query(
    'select round, status, result
    from runs where
    team_id = $1 and service_id = $2 and (status = $3 or $3 is null)
    order by round desc limit 30', $c->param('team_id'), $c->param('service_id'), $c->param('status')
  )->expand->hashes->to_array;
  $c->render(view => $view);
}

1;
