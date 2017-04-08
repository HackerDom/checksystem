package CS::Controller::Api;
use Mojo::Base 'Mojolicious::Controller';

sub info {
  my $c = shift;

  my $info = {};
  $info->{teams}{$_->{id}}    = $_->{name} for values %{$c->app->teams};
  $info->{services}{$_->{id}} = $_->{name} for values %{$c->app->services};
  my $time = $c->model('util')->game_time;
  $c->render(json => {%$info, %$time});
}

sub events {
  my $c = shift;
  $c->tx->with_compression;
  $c->inactivity_timeout(300);

  my $cb1 = $c->pg->pubsub->json('scoreboard')->listen(
    scoreboard => sub {
      my $data = pop;
      $c->send({json => {type => 'state', value => {round => $data->{round}, table => $data->{rank}}}});
    }
  );

  my $cb2 = $c->pg->pubsub->json('flag')->listen(
    flag => sub {
      my $data = pop;
      $data->{attacker_id} = delete $data->{team_id};
      $c->send({json => {type => 'attack', value => $data}});
    }
  );

  $c->on(finish => sub { $c->pg->pubsub->unlisten(scoreboard => $cb1)->unlisten(flag => $cb2); });

  my $data = $c->model('score')->scoreboard_info;
  $c->send({json => {type => 'state', value => {round => $data->{round}, table => $data->{rank}}}});
}

1;
