package CS;
use Mojo::Base 'Mojolicious';

use Mojo::Pg;

has [qw/teams services vulns bots tokens/] => sub { {} };

sub startup {
  my $app = shift;

  push @{$app->commands->namespaces}, 'CS::Command';

  $app->plugin('Config');
  $app->plugin('Model');

  if (my $static = $app->config->{cs}{static}) {
    push @{$app->static->paths}, @$static;
  }

  my $pg_uri = $ENV{TEST_ONLINE} // $app->config->{pg}{uri};
  $app->plugin(Minion => {Pg => $pg_uri});
  $app->helper(
    pg => sub {
      state $pg;
      unless ($pg) {
        $pg = Mojo::Pg->new($pg_uri)->max_connections(32)->auto_migrate(1);
        $pg->migrations->name('cs')->from_file($app->home->rel_file('cs.sql'));
      }
      return $pg;
    }
  );

  # Tasks
  $app->minion->add_task(check => sub { $_[0]->app->model('checker')->check(@_) });
  $app->minion->add_task(
    scoreboard => sub {
      my $app = shift->app;
      my $pg  = $app->pg;

      $app->model('score')->update(@_);
      my $pubsub = $pg->pubsub->json('scoreboard');
      $pubsub->notify('scoreboard');
    }
  );
  $app->minion->add_task(update_irrelevant_services => sub { $_[0]->app->model('service')->update_irrelevant });

  $app->init;

  # Routes
  my $r = $app->routes;

  # Optional frontend app from index.html
  if ($app->static->file('index.html')) {
    $r->get('/')->to(cb => sub { shift->reply->static('index.html') });
    $r->get('/board')->to('main#index')->name('index');
  } else {
    $r->get('/')->to('main#index')->name('index');
  }
  $r->get('/team/:team_id')->to('main#team')->name('team');
  $r->websocket('/update')->to('main#update')->name('update');
  $r->get('/scoreboard'         => [format => 'json'])->to('main#scoreboard')->name('scoreboard');
  $r->get('/history/scoreboard' => [format => 'json'])->to('main#scoreboard_history')
    ->name('scoreboard_history');
  $r->get('/ctftime/scoreboard' => [format => 'json'])->to('main#ctftime_scoreboard');
  $r->get('/fb' => [format => 'json'])->to('main#fb');
  $r->get('/t' => [format => 'json'])->to('main#t');

  # Flags
  $r->put('/flags')->to('flags#put')->name('flags');
  $r->get('/flag_ids')->to('flags#list')->name('flag_ids');

  # API
  $r->websocket('/api/events')->to('api#events')->name('api_events');
  $r->get('/api/info')->to('api#info')->name('api_info');
  $r->get('/teams')->to('api#teams')->name('teams');
  $r->get('/services')->to('api#services')->name('services');

  # Admin
  my $admin = $r->under('/admin')->to('admin#auth');
  $admin->get('/')->to('admin#index')->name('admin_index');
  $admin->get('/info')->to('admin#info')->name('admin_info');
  $admin->get('/view/:team_id/:service_id')->to('admin#view')->name('admin_view');

  # Minion Admin
  $app->plugin('Minion::Admin' => {route => $admin->any('/minion')});

  $app->hook(
    before_dispatch => sub {
      my $c = shift;
      if (my $base_url = $c->config->{cs}{base_url}) { $c->req->url->base(Mojo::URL->new($base_url)); }
    }
  );

  $app->hook(after_static => sub { shift->res->headers->cache_control('max-age=3600, must-revalidate'); });
}

sub init {
  my $app = shift;
  my $db  = $app->pg->db;

  if ($ENV{CS_DEBUG}) {
    $app->teams($db->select('teams')->hashes->reduce(sub { $a->{$b->{id}} = $b; $a }, {}));
    $app->tokens($db->select(teams => '*', {token => {'!=', undef}})->hashes->reduce(sub { $a->{$b->{token}} = $b->{id}; $a }, {}));
    $app->services($db->select('services')->hashes->reduce(sub { $a->{$b->{id}} = $b; $a }, {}));
    return;
  }

  my $teams = $db->select('teams')->hashes->reduce(sub { $a->{$b->{name}} = $b; $a }, {});
  for (@{$app->config->{teams}}) {
    next unless my $team = $teams->{$_->{name}};
    $app->teams->{$team->{id}} = {%$_, %$team};
    $app->tokens->{$team->{token}} = $team->{id} if $team->{token};
  }

  my $services = $db->select('services')->hashes->reduce(sub { $a->{$b->{name}} = $b; $a }, {});
  for (@{$app->config->{services}}) {
    next unless my $service = $services->{$_->{name}};
    my @vulns = split /:/, $service->{vulns};
    my $vulns;
    for my $n (0 .. $#vulns) { push @$vulns, $n + 1 for 1 .. $vulns[$n] }
    $app->services->{$service->{id}} = {%$_, %$service, vulns => $vulns};
  }

  my $bots = $db->select('bots')->hashes->reduce(sub { $a->{$b->{team_id}}{$b->{service_id}} = $b; $a }, {});
  $app->bots($bots);

  my $vulns =
    $db->select('vulns')->hashes->reduce(sub { $a->{$b->{service_id}}{$b->{n}} = $b->{id}; $a }, {});
  $app->vulns($vulns);
}

1;
