package CS::Command::init_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Init db schema';

sub run {
  my $app = shift->app;
  my $db  = $app->pg->db;

  # Teams
  for my $team (@{$app->config->{teams}}) {
    my $values = {
      name    => delete $team->{name},
      network => delete $team->{network},
      host    => delete $team->{host},
      token   => delete $team->{token}
    };
    $values->{id} = delete $team->{id} if defined $team->{id};
    my $details = {details => {-json => $team}};
    $db->insert(teams => {%$values, %$details});
  }

  # Services
  for my $service (@{$app->config->{services}}) {
    my $service_info = $app->model('checker')->info($service);

    my $service_data = {
      name    => $service->{name},
      timeout => $service->{timeout},
      path    => $service->{path},
      vulns   => $service_info->{vulns}{distribution},
      public_flag_description => $service_info->{public_flag_description}
    };
    $service_data->{id} = $service->{id} if defined $service->{id};
    if (my $active = $service->{active}) {
      $service_data->{ts_start} = $active->[0];
      $service_data->{ts_end} = $active->[1];
    }
    my $service_id = $db->insert(services => $service_data, {returning => 'id'})->hash->{id};

    $db->insert(vulns => {service_id => $service_id, n => $_}) for 1 .. $service_info->{vulns}{count};
  }

  # Scores
  $db->insert(rounds => {n => 0});
  $db->query(q{
    insert into service_activity (round, service_id, active, phase)
    select 0, id, false, 'NOT_RELEASED' from services
  });
  $db->query('
    insert into flag_points (round, team_id, service_id, amount)
    select 0, teams.id, services.id, 0 from teams cross join services
  ');
  my $teams = $db->select('teams', ['id', 'details'])->expand->hashes;
  for my $team (@$teams) {
    for my $service_id (keys %{$team->{details}{initial_flag_points} // {}}) {
      $db->query('
        update flag_points set amount = ?
        where round = 0 and team_id = ? and service_id = ?
      ', $team->{details}{initial_flag_points}{$service_id}, $team->{id}, $service_id);
    }
  }
  $db->query('
    insert into sla (round, team_id, service_id, successed, failed)
    select 0, teams.id, services.id, 0, 0 from teams cross join services
  ');
  $app->model('score')->scoreboard($db, 0);
}

1;
