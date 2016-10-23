package CS::Controller::Api;
use Mojo::Base 'Mojolicious::Controller';

sub info {
  my $c = shift;

  my $info = {};
  $info->{teams}{$_->{id}}    = $_->{name} for values %{$c->app->teams};
  $info->{services}{$_->{id}} = $_->{name} for values %{$c->app->services};
  my $time = $c->model('util')->game_time;
  $c->render(json => {%$info, %$time});
}

sub scoreboard {
  my $c  = shift;
  my $pg = $c->pg;

  my $round = $pg->db->query('select max(round) from scores')->array->[0];
  my $table = $pg->db->query('select team_id, score from scoreboard where round = ?', $round)
    ->hashes->reduce(sub { $a->{$b->{team_id}} = $b->{score}; $a; }, {});

  $c->render(json => {round => $round, table => $table});
}

sub events {
  my $c  = shift;
  my $pg = $c->pg;

  my $round = $c->param('from') // 0;
  my $events = $pg->db->query(
    'select extract(epoch from sf.ts)::int, f.service_id, sf.team_id, f.team_id
		from stolen_flags as sf join flags as f using(data) where sf.round >= ?', $round
  )->arrays;
  $c->render(json => $events->to_array);
}

1;
