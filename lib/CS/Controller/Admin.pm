package CS::Controller::Admin;
use Mojo::Base 'Mojolicious::Controller';

use List::Util 'all';
use Mojo::Util 'b64_decode';

sub auth {
  my $c = shift;

  my $auth = $c->req->headers->authorization // '';
  unless ($auth) {
    $c->res->headers->www_authenticate('Basic');
    $c->render(text => 'Authentication required!', status => 401);
    return undef;
  }
  $auth =~ s/^Basic\s//;
  my $line = b64_decode $auth;

  return 1 if $line eq $c->config->{cs}{admin}{auth};

  $c->res->headers->www_authenticate('Basic');
  $c->render(text => 'Authentication required!', status => 401);
  return undef;
}

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub view {
  my $c  = shift;
  my $db = $c->pg->db;

  my $team    = $c->app->teams->{$c->param('team_id')};
  my $service = $c->app->services->{$c->param('service_id')};

  return $c->reply->not_found
    unless ($team->{id} || ($c->param('team_id') eq '*'))
    && ($service->{id} || ($c->param('service_id') eq '*'));

  my $status = $c->param('status');
  if ($status) {
    $status = undef if $status eq 'all' || all { $status != $_ } (101, 102, 103, 104, 110);
  }

  my $last = $db->query(
    'select count(*)
    from runs where
    (team_id = $1 or $1 is null) and (service_id = $2 or $2 is null) and (status = $3 or $3 is null)',
    $team->{id}, $service->{id}, $status
  )->array->[0];
  my $limit = int($c->param('limit') // 0) || 30;
  my $max   = int($last / $limit) + 1;

  my $page = int($c->param('page') // 1);
  $page = 1    if $page < 1;
  $page = $max if $page > $max;
  my $offset = ($page - 1) * $limit;

  my $view = $db->query(
    'select round, status, result
    from runs where
    (team_id = $1 or $1 is null) and (service_id = $2 or $2 is null) and (status = $3 or $3 is null)
    order by round desc limit $4 offset $5', $team->{id}, $service->{id}, $status, $limit, $offset
  )->expand->hashes->to_array;
  $c->render(view => $view, page => $page, max => $max);
}

1;
