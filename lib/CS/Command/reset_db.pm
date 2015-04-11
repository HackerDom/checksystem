package CS::Command::reset_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Clean db.';

sub run {
  my $app = shift->app;
  my $pg  = $app->pg;

  $pg->db->query('drop table if exists rounds, teams, services, flags, stolen_flags, runs, sla');
  $pg->db->query("delete from mojo_migrations where name = 'cs'");
  $pg->migrations->name('cs')->migrate(0)->migrate;
}

1;
