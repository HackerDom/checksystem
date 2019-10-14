package CS::Command::board_reload;
use Mojo::Base 'Mojolicious::Command';

has description => 'Send reload to scoreboard via API';

sub run {
  my $app = shift->app;

  $app->pg->pubsub->notify('reload');
}

1;
