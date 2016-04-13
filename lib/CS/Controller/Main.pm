package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub charts_data {
  my $c = shift;

  my $db = $c->pg->db;
  my $tx = $db->begin;
  $db->query('set transaction isolation level repeatable read');
  my $scores = $db->query(
    'select team_id as name, array_agg(score order by round) as data from scoreboard group by team_id')
    ->expand->hashes;
  my $rounds = $db->query('select distinct(round) from scoreboard order by 1')->arrays->flatten;
  my $flags  = $db->query(
    q{select service_id as name, array_agg(flags order by round)::int[] as data
from
(select round, (service->>'id')::int as service_id, sum((service->>'flags')::int) as flags
  from (select round, team_id, json_array_elements(services) as service from scoreboard) as s
group by 1, 2) as ss
group by service_id}
  )->expand->hashes;

  $c->render(json => {rounds => $rounds, scores => $scores, flags => $flags});
}

sub scoreboard {
  my $c = shift;
  $c->render(json => $c->model('scoreboard')->generate);
}

sub update {
  my $c = shift->render_later;
  $c->inactivity_timeout(300);

  return $c->finish if $c->model('util')->game_status == -1;

  my $id = Mojo::IOLoop->recurring(
    15 => sub {
      $c->stash(%{$c->model('scoreboard')->generate});
      my $round      = $c->stash('round');
      my $scoreboard = $c->render_to_string('scoreboard')->to_string;

      $c->send({json => {round => "Round $round", scoreboard => $scoreboard}});
    }
  );

  $c->on(finish => sub { Mojo::IOLoop->remove($id) });
}

1;
