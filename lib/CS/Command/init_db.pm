package CS::Command::init_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Init db schema';

sub run {
  my $app = shift->app;
  my $db  = $app->pg->db;

  # Teams
  for my $team (@{$app->config->{teams}}) {
    $db->query('insert into teams (name, network, host) values (?, ?, ?)', @{$team}{qw/name network host/});
  }

  # Services
  for my $service (@{$app->config->{services}}) {
    my ($n, $vulns) = $app->model('checker')->vulns($service);
    my $service_id =
      $db->query('insert into services (name, vulns) values (?, ?) returning id', $service->{name}, $vulns)
      ->hash->{id};
    $db->query('insert into vulns (service_id, n) values (?, ?)', $service_id, $_) for 1 .. $n;
  }

  # Scores
  $db->query('insert into rounds (n) values (0)');
  $db->query(
    'insert into flag_points (round, team_id, service_id, amount)
      select 0, teams.id, services.id, 0 from teams cross join services'
  );
  $db->query(
    'insert into sla (round, team_id, service_id, successed, failed)
      select 0, teams.id, services.id, 0, 0 from teams cross join services'
  );
  $app->model('score')->scoreboard($db, 0);
}

1;
