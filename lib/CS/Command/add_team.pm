package CS::Command::add_team;
use Mojo::Base 'Mojolicious::Command';

use Mojo::JSON 'j';

has description => 'Add new team to current game';

sub run {
  my $app = shift->app;

  my $team_info = j(shift);
  die "There is no team info details" unless $team_info;

  my $db  = $app->pg->db;
  my $tx = $db->begin;

  my $values = {
    name    => delete $team_info->{name},
    network => delete $team_info->{network},
    host    => delete $team_info->{host},
    token   => delete $team_info->{token}
  };
  my $details = {details => {-json => $team_info}};
  my $team = $db->insert(teams => {%$values, %$details}, {returning => '*'})->expand->hash;

  # Scores
  $db->query('
    insert into flag_points (round, team_id, service_id, amount)
    select (select max(round) from scores), ?, id, 0 from services
  ', $team->{id});
  $db->query('
    insert into sla (round, team_id, service_id, successed, failed)
    select (select max(round) from scores), ?, id, 0, 0 from services
  ', $team->{id});

  $tx->commit;
}

1;
