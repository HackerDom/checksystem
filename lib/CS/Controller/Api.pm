package CS::Controller::Api;
use Mojo::Base 'Mojolicious::Controller';

use Sereal::Dclone 'dclone';

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
      my $value = $c->model('scoreboard')->generate;
      $c->send({json => {type => 'state', value => $value}});
    }
  );

  my $cb2 = $c->pg->pubsub->json('flag')->listen(
    flag => sub {
      my $data = dclone(pop);
      $c->app->log($c->app->dumper($data));
      $data->{attacker_id} = delete $data->{team_id};
      $c->send({json => {type => 'attack', value => $data}});
    }
  );

  $c->on(finish => sub { $c->pg->pubsub->unlisten(scoreboard => $cb1)->unlisten(flag => $cb2); });

  my $data = $c->model('scoreboard')->generate;
  $c->send({json => {type => 'state', value => $data}});
}

1;
