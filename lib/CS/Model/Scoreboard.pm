package CS::Model::Scoreboard;
use Mojo::Base 'MojoX::Model';

sub generate {
  my $self = shift;
  my $db   = $self->app->pg->db;

  my $scoreboard = $db->query(
    'select t.host, t.name, s.* from scoreboard as s join teams as t on s.team_id = t.id
      where round = (select max(round) from scoreboard) order by n'
  )->expand->hashes;
  my $round = $db->query('select max(n) from scoreboard')->array->[0];

  return {scoreboard => $scoreboard->to_array, round => $round};
}

1;
