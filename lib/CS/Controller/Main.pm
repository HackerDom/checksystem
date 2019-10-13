package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub team {
  my $c = shift;
  return $c->reply->not_found unless my $team = $c->app->teams->{$c->param('team_id')};

  $c->render(%{$c->model('scoreboard')->generate_for_team($team->{id})}, team => $team);
}

sub scoreboard {
  my $c = shift;
  $c->render(json => $c->model('scoreboard')->generate);
}

sub scoreboard_history {
  my $c = shift;
  $c->render(json => $c->model('scoreboard')->generate_history);
}

sub update {
  my $c = shift->render_later;
  $c->tx->with_compression;
  $c->inactivity_timeout(300);

  my ($game_status) = $c->model('util')->game_status;
  return $c->finish if $game_status == -1;

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
