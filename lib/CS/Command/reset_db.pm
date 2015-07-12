package CS::Command::reset_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Clean db';

sub run {
  my $app = shift->app;
  my $pg  = $app->pg;

  # Jobs
  $app->minion->reset;

  # Migrations
  $pg->migrations->active;
  $pg->migrations->name('cs')->migrate(0)->migrate;
}

1;
