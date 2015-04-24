package CS::Model::Achievement;
use Mojo::Base 'MojoX::Model';

sub verify {
  my ($self, $flag_data, $n) = @_;
  my $app = $self->app;
  my $db  = $app->pg->db;

  my $flag = $db->query(
    'select sf.ts, sf.team_id, f.service_id from stolen_flags as sf join flags as f using(data)
    where data = ?', $flag_data
  )->hash;
  my ($team_id, $service_id) = @{$flag}{qw/team_id service_id/};
  my ($team, $service) = ($app->teams->{$team_id}{name}, $app->services->{$service_id}{name});

  # First blood
  $n = $db->query(
    'select count(*) from stolen_flags as sf join flags as f using(data) where sf.ts < ? and service_id = ?',
    $flag->{ts}, $service_id
  )->array->[0];
  $self->_create(sprintf('%s on %s get first blood', $team, $service)) if $n == 0;

  # First flag (team/service)
  $n = $db->query(
    'select count(*)
    from stolen_flags as sf join flags as f using(data)
    where sf.ts < ? and service_id = ? and sf.team_id = ?', $flag->{ts}, $service_id, $team_id
  )->array->[0];
  $self->_create(sprintf('%s on %s get first flags', $team, $service)) if $n == 0;

  # N flags (team/service)
  $n = $db->query(
    'select count(*)
    from stolen_flags as sf join flags as f using(data)
    where sf.ts <= ? and service_id = ? and sf.team_id = ?', $flag->{ts}, $service_id, $team_id
  )->array->[0];
  $self->_create(sprintf('%s on %s get %d flags', $team, $service, $n)) if $n > 0 && $n % 10 == 0;

  # N services
  my $services;
  $db->query(
    'select distinct(service_id) from stolen_flags as sf join flags as f using(data)
    where sf.ts < ? and sf.team_id = ?', $flag->{ts}, $team_id
  )->arrays->map(sub { $services->{$_->[0]} = undef });
  if (!exists $services->{$service_id}) {
    $n = 1 + keys %$services;
    $self->_create(sprintf('%s hack %d services', $team, $n)) if $n > 1;
  }
}

sub _create { $_[0]->app->pg->db->query('insert into achievement (data) values (?)', $_[1]) }

1;
