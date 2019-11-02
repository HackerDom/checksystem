package CS::Controller::Api;
use Mojo::Base 'Mojolicious::Controller';

use Sereal::Dclone 'dclone';

sub info {
  my $c = shift;

  my $info = {};
  for (values %{$c->app->teams}) {
    my $team = dclone $_;
    delete $team->{token};
    delete $team->{bot};
    $info->{teams}{$_->{id}} = $team;
  }
  $info->{services}{$_->{id}} = $_->{name} for values %{$c->app->services};

  my $time = $c->model('util')->game_time;

  $c->render(json => {%$info, %$time});
}

sub events {
  my $c = shift;
  $c->tx->with_compression;
  $c->inactivity_timeout(300);
  my $pubsub = $c->pg->pubsub;

  my $cb1 = $pubsub->json('scoreboard')->listen(
    scoreboard => sub {
      my $value = $c->model('scoreboard')->generate;
      $c->send({json => {type => 'state', value => $value}});
    }
  );

  my $cb2 = $pubsub->json('flag')->listen(
    flag => sub {
      my $data = dclone(pop);
      $data->{attacker_id} = delete $data->{team_id};
      $c->send({json => {type => 'attack', value => $data}});
    }
  );

  my $cb3 = $pubsub->listen(
    message => sub {
      my $msg = pop;
      $c->send({json => {type => 'message', value => $msg}});
    }
  );

  my $cb4 = $pubsub->listen(reload => sub { $c->send({json => {type => 'reload'}}) });

  $c->on(finish => sub { $pubsub->unlisten(scoreboard => $cb1)->unlisten(flag => $cb2)->unlisten(message => $cb3)->unlisten(reload => $cb4) });

  my $data = $c->model('scoreboard')->generate;
  $c->send({json => {type => 'state', value => $data}});
}

1;
