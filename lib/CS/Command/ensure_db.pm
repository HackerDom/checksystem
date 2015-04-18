package CS::Command::ensure_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Ensure db schema.';

sub run {
  my $app = shift->app;
  my $db  = $app->pg->db;

  # Ensure teams
  for my $team (@{$app->config->{teams}}) {
    my ($name, $network, $host) = @{$team}{qw/name network host/};
    eval { $db->query('insert into teams (name, network, host) values (?, ?, ?)', $name, $network, $host); };
    $db->query('update teams set (name, network, host) = ($1, $2, $3) where name = $1',
      $name, $network, $host);
  }

  # Ensure services
  for my $service (@{$app->config->{services}}) {
    eval { $db->query('insert into services (name) values (?)', $service->{name}) };
  }

  # Init
  $db->query('insert into rounds (n) values (0)');
  $db->query(
    'insert into score (round, team_id, service_id, score)
      select 0, teams.id, services.id, (select 100 * ?)
      from teams cross join services', 0 + @{$app->config->{teams}}
  );
  $db->query(
    'insert into sla (round, team_id, service_id, successed, failed)
      select 0, teams.id, services.id, 0, 0
      from teams cross join services'
  );
}

1;
