package CS::Controller::Api;
use Mojo::Base 'Mojolicious::Controller';

use Sereal::Dclone 'dclone';
use Time::Piece;

sub info {
  my $c = shift;

  my $info = {};
  $info->{teams}{$_->{id}}    = $_->{name} for values %{$c->app->teams};
  $info->{services}{$_->{id}} = $_->{name} for values %{$c->app->services};

  my $time = $c->model('util')->game_time;
  $time->{start} += localtime->tzoffset;
  $time->{end}   += localtime->tzoffset;

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

  $c->on(finish => sub { $pubsub->unlisten(scoreboard => $cb1)->unlisten(flag => $cb2); });

  my $data = $c->model('scoreboard')->generate;
  $c->send({json => {type => 'state', value => $data}});
}

sub notifications {
  my $c = shift;
  $c->tx->with_compression;
  $c->inactivity_timeout(300);
  my $pubsub =
    $c->pg->pubsub->json('team_position_changed')->json('scoreboard_updated')->json('service_status_changed');

  my $opts = {};

  my $cb1 = $pubsub->listen(
    team_position_changed => sub {
      my $data = pop;

      if ($opts->{team_position_changed}{$data->{team_id}}) {
        $c->send({json => {event => 'team_position_changed', team_id => $data->{team_id}, data => $data}});
      }
    }
  );

  my $cb2 = $pubsub->listen(
    scoreboard_updated => sub {
      my $data = pop;

      if ($opts->{scoreboard_updated}{$data->{team_id}}) {
        $c->send({json => {event => 'scoreboard_updated', team_id => $data->{team_id}, data => $data}});
      }
    }
  );

  my $cb3 = $pubsub->listen(
    service_status_changed => sub {
      my $data = pop;

      if ($opts->{service_status_changed}{$data->{team_id}}) {
        $c->send({json => {event => 'service_status_changed', team_id => $data->{team_id}, data => $data}});
      }
    }
  );

  # {"subscribe": "team_position_changed", "team_id": 1}
  # {"subscribe": "scoreboard_updated", "team_id": 1}
  $c->on(
    json => sub {
      my $message = pop;

      if (my $event = $message->{subscribe}) {
        my $team_id = $message->{team_id};
        $opts->{$event}{$team_id} = 1;
      } elsif (my $command = $message->{command}) {
        my $response = {command => $command, id => $message->{id}};

        if ($command eq 'scoreboard') {
          my $top = $message->{top};
          $response->{data} = $c->model('scoreboard')->generate(undef, $top);
        }

        $c->send({json => $response});
      }
    }
  );

  $c->on(
    finish => sub {
      $pubsub->unlisten(team_position_changed => $cb1)->unlisten(scoreboard_updated => $cb2)
        ->unlisten(service_status_changed => $cb3);
    }
  );
}

1;
