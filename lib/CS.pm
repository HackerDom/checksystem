package CS;
use Mojo::Base 'Mojolicious';

use Mojo::Pg;

has teams    => sub { {} };
has services => sub { {} };

sub startup {
  my $app = shift;

  push @{$app->commands->namespaces}, 'CS::Command';

  $app->plugin('Config');
  $app->plugin('Model');
  $app->plugin(Minion => {Pg => $app->config->{pg}{uri}});

  $app->helper(pg => sub { state $pg = Mojo::Pg->new($app->config->{pg}{uri}) });

  # Tasks
  $app->minion->add_task(check => sub { $_[0]->app->model('checker')->check(@_) });

  # Migrations
  $app->pg->migrations->name('cs')->from_file($app->home->rel_file('cs.sql'));
  $app->pg->migrations->migrate;

  $app->init;
}

sub init {
  my $app = shift;

  $app->teams(
    $app->pg->db->query('select * from teams')->hashes->reduce(sub { $a->{$b->{id}} = $b; $a }, {}));

  my $services =
    $app->pg->db->query('select * from services')->hashes->reduce(sub { $a->{$b->{name}} = $b; $a }, {});
  for (@{$app->config->{services}}) {
    my $service = $services->{$_->{name}};
    $app->services->{$service->{id}} = {id => $service->{id}, %$_};
  }
}

1;
