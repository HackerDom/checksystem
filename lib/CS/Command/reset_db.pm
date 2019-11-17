package CS::Command::reset_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Reset db';

sub run {
  my $app = shift->app;

  # Jobs
  $app->minion->reset({all => 1});

  # Migrations
  $app->pg->migrations->active;
  $app->pg->migrations->name('cs')->migrate(0)->migrate;
}

1;
