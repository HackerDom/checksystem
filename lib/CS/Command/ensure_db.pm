package CS::Command::ensure_db;
use Mojo::Base 'Mojolicious::Command';

has description => 'Ensure db schema.';

sub run {
  my $app = shift->app;
  my $pg  = $app->pg;

  for my $team (@{$app->config->{teams}}) {
    my ($name, $network, $host) = @{$team}{qw/name network host/};
    eval {
      $pg->db->query('insert into teams (name, network, host) values (?, ?, ?)', $name, $network, $host);
    };
    $pg->db->query('update teams set (name, network, host) = ($1, $2, $3) where name = $1',
      $name, $network, $host);
  }

  for my $service (@{$app->config->{services}}) {
    eval { $pg->db->query('insert into services (name) values (?)', $service->{name}) };
  }
}

1;
