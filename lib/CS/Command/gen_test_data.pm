package CS::Command::gen_test_data;
use Mojo::Base 'Mojolicious::Command';

has description => 'Generate test data';

sub run {
  my $app = shift->app;
  my $db  = $app->pg->db;

  $app->commands->run('reset_db');
  $app->commands->run('init_db');

  $db->query(
    "insert into rounds (ts)
    select generate_series(now(), now() + interval '0.5 hour', interval '1 minute')"
  );
  $db->query(
    "insert into runs select
    rounds.n, rounds.ts, teams.id, services.id, 1, trunc(random() * 4) + 101, '{}', md5(random()::text)
    from rounds cross join teams cross join services"
  );
  $db->query(
    "insert into flags
    select
    md5((random() * random())::text), md5(random()::text), round, ts, team_id, service_id, vuln_id
    from runs where status = 101"
  );

  $app->model('score')->update;
}

1;
