package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub charts_data {
  my $c  = shift;
  my $pg = $c->pg;

  $c->delay(
    sub {
      my $delay = shift;
      $pg->db->query(
        'select team_id as name, array_agg(score order by round) as data from scoreboard group by team_id',
        $delay->begin);
      $pg->db->query('select distinct(round) from scoreboard order by 1', $delay->begin);
      $pg->db->query('
        select service_id as name, array_agg(flags order by round)::int[] as data
        from (select round, service_id, sum(flags) as flags from scores group by round, service_id) as s
        group by service_id', $delay->begin);
    },
    sub {
      my ($delay, undef, $scores, undef, $rounds, undef, $flags) = @_;
      $c->render(
        json => {
          rounds => $rounds->arrays->flatten,
          scores => $scores->expand->hashes,
          flags  => $flags->expand->hashes
        }
      );
    }
  );
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
