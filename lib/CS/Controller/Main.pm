package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index {
  my $c = shift;

  my ($round, $scoreboard, $progress) = $c->model('scoreboard')->generate;
  $c->render(scoreboard => $scoreboard, round => $round, progress => $progress);
}

sub update {
  my $c = shift->render_later;
  $c->inactivity_timeout(300);

  my $id = Mojo::IOLoop->recurring(
    15 => sub {
      my ($round, $scoreboard, $progress) = $c->model('scoreboard')->generate;
      $c->stash(scoreboard => $scoreboard, round => $round, progress => $progress);
      $c->send({
          json => {
            round      => "Round $round",
            scoreboard => $c->render_to_string('scoreboard'),
            progress   => $c->render_to_string('progress')
          }
        }
      );
    }
  );

  $c->on(finish => sub { Mojo::IOLoop->remove($id) });
}

1;
