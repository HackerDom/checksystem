package CS::Controller::Flags;
use Mojo::Base 'Mojolicious::Controller';

sub put {
  my $c = shift->render_later;

  my ($game_status) = $app->model('util')->game_status;
  unless ($game_status == 1) {
    return $c->render(json => {status => \0, msg => 'Game is not active for now'}, status => 400);
  }

  if ($c->req->body_size > 16 * 1024) {
    return $c->render(json => {status => \0, msg => 'Message is too big'}, status => 400);
  }

  my $token = $c->req->headers->header('X-Team-Token') // '';
  return $c->render(json => {status => \0, msg => "Invalid token '$token'"}, status => 400)
    unless my $team_id = $c->app->tokens->{$token};

  my $flags = $c->req->json // [];
  my $results = [];

  my $do;
  $do = sub {
    my $flag = shift @$flags;

    unless ($flag) {
      undef $do;
      $c->render(json => $results);
      return;
    }

    $c->model('flag')->accept(
      $team_id, $flag,
      sub {
        my $msg = $_[0]->{ok} ? $_[0]->{message} : $_[0]->{error};
        push @$results, {flag => $flag, status => \$_[0]->{ok}, msg => $msg};
        $do->();
      }
    );
  };

  $do->();
}

1;
