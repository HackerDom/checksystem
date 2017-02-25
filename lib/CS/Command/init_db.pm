package CS::Command::init_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Init db schema';

sub run {
  my $app = shift->app;
  my $db  = $app->pg->db;

  # Teams
  for my $team (@{$app->config->{teams}}) {
    $db->insert(teams => {%{$team}{qw/name network host bonus/}});
  }

  # Services
  for my $service (@{$app->config->{services}}) {
    my ($n, $vulns) = $app->model('checker')->vulns($service);
    my $name = $service->{name};
    my $id = $db->insert(services => {name => $name, vulns => $vulns}, {returning => 'id'})->hash->{id};
    $db->insert(vulns => {service_id => $id, n => $_}) for 1 .. $n;
  }

  # Scores
  $db->insert(rounds => {n => 0});
  $db->query('
    insert into flag_points (round, team_id, service_id, amount)
    select 0, teams.id, services.id, ? from teams cross join services', 0 + @{$app->config->{teams}});
  $db->query('
    insert into sla (round, team_id, service_id, successed, failed)
    select 0, teams.id, services.id, 0, 0 from teams cross join services'
  );
  $app->model('score')->scoreboard($db, 0);
}

1;
