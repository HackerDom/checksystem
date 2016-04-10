package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub charts_data {
  my $c  = shift;
  my $db = $c->pg->db;

  my $scores = $db->query('select team_name as name, scores as data from scoreboard_history')->expand->hashes;
  my $scoreboard =
    $db->query('select n, name from scoreboard')->hashes->reduce(sub { $a->{$b->{name}} = $b->{n}; $a; }, {});
  my $rounds = $db->query('select n from rounds')->arrays->flatten->to_array;

  $c->render(json => {rounds => $rounds, scores => $scores, scoreboard => $scoreboard});
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
