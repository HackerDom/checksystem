package CS::Command::board_message;
use Mojo::Base 'Mojolicious::Command';

has description => 'Send message to scoreboard via API';

sub run {
  my $app = shift->app;
  my $msg = shift;

  $app->pg->pubsub->notify(message => $msg);
}

1;
