package CS::Model::Scoreboard;
use Mojo::Base 'MojoX::Model';

sub generate {
  my ($self, $round) = @_;
  my $db = $self->app->pg->db;

  $round //= $db->query('select max(round) from scoreboard')->array->[0];
  my $scoreboard = $db->query('
    select t.host, t.name, s1.n - s.n as d, s.*
      from scoreboard as s
      join teams as t on s.team_id = t.id
      join (
        select team_id, n from scoreboard where round = case when $1-1 < 0 then 0 else $1-1 end
      ) as s1 using (team_id)
    where round = $1 order by n', $round)->expand->hashes;

  return {scoreboard => $scoreboard->to_array, round => $round};
}

1;
