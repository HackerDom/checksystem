package CS;
use Mojo::Base 'Mojolicious';

use Mojo::Pg;

sub startup {
  my $app = shift;

  push @{$app->commands->namespaces}, 'CS::Command';

  $app->plugin('Config' => {default => {path => ''}});
  $app->plugin('Model');
  $app->plugin(Minion => {Pg => $app->config->{pg}{uri}});

  $app->helper(pg => sub { state $pg = Mojo::Pg->new($app->config->{pg}{uri}) });

  # Tasks
  $app->minion->add_task(check => sub { $_[0]->app->model('checker')->check(@_) });

  # Migrations
  $app->pg->migrations->name('cs')->from_file($app->home->rel_file('cs.sql'));
  $app->pg->migrations->migrate;
}

1;
