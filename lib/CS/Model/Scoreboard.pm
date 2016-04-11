package CS::Model::Scoreboard;
use Mojo::Base 'MojoX::Model';

sub generate {
  my ($self, $round) = @_;
  my $db = $self->app->pg->db;

  $round //= $db->query('select max(round) from scoreboard')->array->[0];
  my $scoreboard = $db->query(
    'select t.host, t.name, s.* from scoreboard as s join teams as t on s.team_id = t.id
      where round = ? order by n', $round
  )->expand->hashes;


  return {scoreboard => $scoreboard->to_array, round => $round};
}

1;
