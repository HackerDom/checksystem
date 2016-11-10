package CS;
use Mojo::JSON::MaybeXS;
use Mojo::Base 'Mojolicious';

use Fcntl ':flock';
use InfluxDB::LineProtocol 'data2line';
use Mojo::Pg;

has [qw/teams services vulns/] => sub { {} };

sub startup {
  my $app = shift;

  push @{$app->commands->namespaces}, 'CS::Command';

  $app->plugin('Config');
  $app->plugin('Model');

  my $pg_uri = $ENV{TEST_ONLINE} // $app->config->{pg}{uri};
  $app->plugin(Minion => {Pg => $pg_uri});
  $app->helper(
    pg => sub {
      state $pg;
      unless ($pg) {
        $pg = Mojo::Pg->new($pg_uri)->max_connections(1000)->auto_migrate(1);
        $pg->migrations->name('cs')->from_file($app->home->rel_file('cs.sql'));
      }
      return $pg;
    }
  );

  $app->helper(
    'metric.write' => sub {
      my (undef, $measure, $values, $tags, $ts) = @_;
      state $handle;

      unless ($handle) {
        open $handle, '>>', $app->home->rel_file('log/metrics.log') or die "Can't open metrics log file: $!";
      }

      my $line = data2line($measure, $values, $tags, $ts);

      flock $handle, LOCK_EX;
      $handle->print("$line\n");
      flock $handle, LOCK_UN;
    }
  );

  # Tasks
  $app->minion->add_task(check => sub { $_[0]->app->model('checker')->check(@_) });
  $app->minion->add_task(
    scoreboard => sub {
      my $app = shift->app;
      my $pg  = $app->pg;

      $app->model('score')->update(@_);
      $pg->pubsub->json('scoreboard')->notify(scoreboard => $app->model('score')->scoreboard_info);
    }
  );

  $app->init;

  # Routes
  my $r = $app->routes;
  $r->get('/')->to('main#index')->name('index');
  $r->get('/team/:team_id')->to('main#team')->name('team');
  $r->websocket('/update')->to('main#update')->name('update');
  $r->get('/scoreboard' => [format => 'json'])->to('main#scoreboard')->name('scoreboard');

  # API
  my $api = $r->route('/api');
  $api->get('/info')->to('api#info')->name('api_info');
  $api->get('/scoreboard')->to('api#scoreboard')->name('api_scoreboard');
  $api->get('/events')->to('api#events')->name('api_events');

  # Admin
  my $admin = $r->under('/admin')->to('admin#auth');
  $admin->get('/')->to('admin#index')->name('admin_index');
  $admin->get('/view/:team_id/:service_id')->to('admin#view')->name('admin_view');

  $app->hook(
    before_dispatch => sub {
      my $c = shift;
      if (my $base_url = $c->config->{cs}{base_url}) { $c->req->url->base(Mojo::URL->new($base_url)); }
    }
  );
}

sub init {
  my $app = shift;

  if ($ENV{CS_DEBUG}) {
    $app->teams($app->pg->db->query('table teams')->hashes->reduce(sub { $a->{$b->{id}} = $b; $a }, {}));
    $app->services(
      $app->pg->db->query('table services')->hashes->reduce(sub { $a->{$b->{id}} = $b; $a }, {}));
    return;
  }

  my $teams = $app->pg->db->query('table teams')->hashes->reduce(sub { $a->{$b->{name}} = $b; $a }, {});
  for (@{$app->config->{teams}}) {
    next unless my $team = $teams->{$_->{name}};
    $app->teams->{$team->{id}} = {id => $team->{id}, %$_};
  }

  my $services = $app->pg->db->query('table services')->hashes->reduce(sub { $a->{$b->{name}} = $b; $a }, {});
  for (@{$app->config->{services}}) {
    next unless my $service = $services->{$_->{name}};
    my @vulns = split /:/, $service->{vulns};
    my $vulns;
    for my $n (0 .. $#vulns) { push @$vulns, $n + 1 for 1 .. $vulns[$n] }
    $app->services->{$service->{id}} = {id => $service->{id}, %$_, vulns => $vulns};
  }

  $app->vulns($app->pg->db->query('table vulns')
      ->hashes->reduce(sub { $a->{$b->{service_id}}{$b->{n}} = $b->{id}; $a }, {}));
}

1;
