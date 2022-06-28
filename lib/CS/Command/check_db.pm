package CS::Command::check_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Check db for init game';

sub run {
  my $app = shift->app;

  my $round = $app->pg->db->select(rounds => 'count(*)')->array->[0];
  die "There is no data in rounds table" unless $round;

  my $teams = $app->pg->db->select(teams => 'count(*)')->array->[0];
  die "Teams in config and db are different" unless $teams == @{$app->config->{teams}};

  my $services = $app->pg->db->select(services => 'count(*)')->array->[0];
  die "Services in config and db are different" unless $services == @{$app->config->{services}};
}

1;
