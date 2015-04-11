package CS::Model::Score;
use Mojo::Base 'MojoX::Model';

sub sla {
  my $app = shift->app;
  my $db  = $app->pg->db;

  my $r = 1 + ($db->query('select max(round) as n from sla')->hash->{n} // 0);
  $app->log->debug("Attempt calc SLA for round #$r");

  # Check for new round
  return unless $db->query('select * from rounds where n > ?', $r)->rows;
  $app->log->debug("Calc SLA for round #$r");

  my $state = $db->query('select * from sla where round = ?', $r - 1)->hashes->reduce(
    sub {
      $a->{$b->{team_id}}{$b->{service_id}} = $b;
    },
    {}
  );
  $db->query('
    with r as (
      select team_id, service_id, status from runs where round = ?
    ),
    teams_x_services as (
      select teams.id as team_id, services.id as service_id
      from teams cross join services
    )
    select * from teams_x_services left join r using (team_id, service_id)
    ', $r)->hashes->map(
    sub {
      if (($_->{status} // 110) == 101) {
        ++$state->{$_->{team_id}}{$_->{service_id}}{successed};
      } else {
        ++$state->{$_->{team_id}}{$_->{service_id}}{failed};
      }
    }
  );

  my $sql = sprintf('insert into sla (round, team_id, service_id, successed, failed) values %s',
    join(', ', ('(?, ?, ?, ?, ?)') x (keys(%{$app->teams}) * keys(%{$app->services}))));
  my @bind;
  for my $team_id (keys %$state) {
    for my $service_id (keys %{$state->{$team_id}}) {
      my $s = $state->{$team_id}{$service_id};
      push @bind, $r, $team_id, $service_id, $s->{successed} // 0, $s->{failed} // 0;
    }
  }

  $db->query($sql, @bind);
}

1;
