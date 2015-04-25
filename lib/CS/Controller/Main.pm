package CS::Controller::Main;
use Mojo::Base 'Mojolicious::Controller';

sub index { $_[0]->render(%{$_[0]->model('scoreboard')->generate}) }

sub update {
  my $c = shift->render_later;
  $c->inactivity_timeout(300);

  return $c->finish if $c->model('util')->game_status == -1;

  my $achievements;
  my $id = Mojo::IOLoop->recurring(
    15 => sub {
      $c->stash(%{$c->model('scoreboard')->generate});
      my $round = $c->stash('round');
      my $size  = $c->stash('achievement')->size;
      if ($achievements) {
        $c->stash('achievement')->[$_]->{new} = 1 for 0 .. $size - $achievements - 1;
      }
      $achievements = $size;

      $c->send({
          json => {
            round       => "Round $round",
            scoreboard  => $c->render_to_string('scoreboard'),
            progress    => $c->render_to_string('progress'),
            achievement => $c->render_to_string('achievement')
          }
        }
      );
    }
  );

  $c->on(finish => sub { Mojo::IOLoop->remove($id) });
}

1;
