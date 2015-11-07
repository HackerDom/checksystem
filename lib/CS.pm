package CS;
use Mojo::Base 'Mojolicious';

use Mojo::Pg;

has [qw/teams services vulns/] => sub { {} };

sub startup {
  my $app = shift;

  push @{$app->commands->namespaces}, 'CS::Command';

  $app->plugin('Config');
  $app->plugin('Model');

  my $pg_uri = $ENV{TEST_ONLINE} // $app->config->{pg}{uri};
  $app->plugin(Minion => {Pg => $pg_uri});
  $app->helper(pg => sub { state $pg = Mojo::Pg->new($pg_uri) });

  # Tasks
  $app->minion->add_task(check       => sub { $_[0]->app->model('checker')->check(@_) });
  $app->minion->add_task(sla         => sub { shift->app->model('score')->sla(@_) });
  $app->minion->add_task(flag_points => sub { shift->app->model('score')->flag_points(@_) });
  $app->minion->add_task(
    scoreboard => sub { shift->app->pg->db->query('refresh materialized view scoreboard') });

  # Migrations
  $app->pg->migrations->name('cs')->from_file($app->home->rel_file('cs.sql'));
  $app->pg->migrations->migrate;

  $app->init;

  # Routes
  my $r = $app->routes;
  $r->get('/')->to('main#index')->name('index');
  $r->get('/charts')->to('main#charts')->name('charts');
  $r->get('/charts/data')->to('main#charts_data')->name('charts_data');
  $r->websocket('/update')->to('main#update')->name('update');
  my $admin = $r->under('/admin')->to('admin#auth');
  $admin->get('/')->to('admin#index')->name('admin_index');
  $admin->get('/view/:team_id/:service_id')->to('admin#view')->name('admin_view');
}

sub init {
  my $app = shift;

  my $teams = $app->pg->db->query('table teams')->hashes->reduce(sub { $a->{$b->{name}} = $b; $a }, {});
  for (@{$app->config->{teams}}) {
    next unless my $team = $teams->{$_->{name}};
    $app->teams->{$team->{id}} = {id => $team->{id}, %$_};
  }

  my $services = $app->pg->db->query('table services')->hashes->reduce(sub { $a->{$b->{name}} = $b; $a }, {});
  for (@{$app->config->{services}}) {
    next unless my $service = $services->{$_->{name}};
    my @vulns = split /:/, $_->{vulns} // '1';
    my $vulns;
    for my $n (0 .. $#vulns) { push @$vulns, $n + 1 for 1 .. $vulns[$n] }
    $app->services->{$service->{id}} = {id => $service->{id}, %$_, vulns => $vulns};
  }

  $app->vulns($app->pg->db->query('table vulns')
      ->hashes->reduce(sub { $a->{$b->{service_id}}{$b->{n}} = $b->{id}; $a }, {}));
}

1;
