package CS::Command::init_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Init db schema';

sub run {
  my $app = shift->app;
  my $db  = $app->pg->db;

  # Teams
  for my $team (@{$app->config->{teams}}) {
    $db->insert(teams => {%{$team}{qw/name network host token/}});
  }

  # Services
  for my $service (@{$app->config->{services}}) {
    my $service_info = $app->model('checker')->info($service);

    my $service_data = {
      name => $service->{name},
      vulns => $service_info->{vulns}{distribution},
      public_flag_description => $service_info->{public_flag_description}
    };
    if (my $active = $service->{active}) {
      $service_data->{ts_start} = $active->[0];
      $service_data->{ts_end} = $active->[1];
    }
    my $service_id = $db->insert(services => $service_data, {returning => 'id'})->hash->{id};

    $db->insert(vulns => {service_id => $service_id, n => $_}) for 1 .. $service_info->{vulns}{count};
  }

  # Bots
  my $team_id = 0;
  for my $team (@{$app->config->{teams}}) {
    ++$team_id;
    if (my $bot = $team->{bot}) {
      my $service_id = 0;
      for (@$bot) {
        ++$service_id;
        next unless keys %$_;
        my $data = {%$_, team_id => $team_id, service_id => $service_id};
        $db->insert(bots => $data);
      }
    }
  }

  # Scores
  $db->insert(rounds => {n => 0});
  $db->query('
    insert into service_activity_log (round, service_id, active)
    select 0, id, false from services
  ');
  $db->query('
    insert into flag_points (round, team_id, service_id, amount)
    select 0, teams.id, services.id, 1 from teams cross join services
  ');
  $db->query('
    insert into sla (round, team_id, service_id, successed, failed)
    select 0, teams.id, services.id, 0, 0 from teams cross join services
  ');
  $app->model('score')->scoreboard($db, 0);
}

1;
