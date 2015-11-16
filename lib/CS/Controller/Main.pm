package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index { $_[0]->render(%{$_[0]->app->scoreboard}) }

sub charts_data {
  my $c  = shift;
  my $db = $c->pg->db;

  my $scores = $c->pg->db->query(
    'with x as (
      select round, team_id,
      round(sum(100 * score * (case when successed + failed = 0 then 1
        else (successed::double precision / (successed + failed)) end))::numeric, 2) as score
      from score join sla using (round, team_id, service_id)
      group by round, team_id
    )
    select team_id as name, array_agg(score order by round) as data
    from x
    group by team_id'
  )->expand->hashes;

  my $rounds = $db->query('select n from rounds')->arrays->flatten->to_array;

  $c->render(json => {rounds => $rounds, scores => $scores});
}

sub update {
  my $c = shift->render_later;
  $c->inactivity_timeout(300);

  return $c->finish if $c->model('util')->game_status == -1;

  my $id = Mojo::IOLoop->recurring(
    15 => sub {
      $c->stash(%{$c->app->scoreboard});
      my $round = $c->stash('round');

      $c->send({json => {round => "Round $round", scoreboard => $c->render_to_string('scoreboard')}});
    }
  );

  $c->on(finish => sub { Mojo::IOLoop->remove($id) });
}

1;
