package CS::Controller::Admin;
use Mojo::Base 'Mojolicious::Controller';

use List::Util 'all';

sub auth {
  my $c = shift;

  return 1 if ($c->req->url->to_abs->userinfo // '') eq $c->config->{cs}{admin}{auth};
  $c->res->headers->www_authenticate('Basic');
  $c->render(text => 'Authentication required!', status => 401);
  return undef;
}

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub view {
  my $c  = shift;
  my $db = $c->pg->db;

  return $c->reply->not_found
    unless (my $team = $c->app->teams->{$c->param('team_id')})
    && (my $service = $c->app->services->{$c->param('service_id')});

  my $status = $c->param('status');
  if ($status) {
    $status = undef if $status eq 'all' || all { $status != $_ } (101, 102, 103, 104, 110);
  }

  my $last = $db->query(
    'select count(*)
    from runs where
    team_id = $1 and service_id = $2 and (status = $3 or $3 is null)', $team->{id}, $service->{id}, $status
  )->array->[0];
  my $limit = 30;
  my $max   = int($last / $limit) + 1;

  my $page = int($c->param('page') // 1);
  $page = 1    if $page < 1;
  $page = $max if $page > $max;
  my $offset = ($page - 1) * $limit;

  my $view = $db->query(
    'select round, status, result
    from runs where
    team_id = $1 and service_id = $2 and (status = $3 or $3 is null)
    order by round desc limit $4 offset $5', $team->{id}, $service->{id}, $status, $limit, $offset
  )->expand->hashes->to_array;
  $c->render(view => $view, page => $page, max => $max);
}

1;
