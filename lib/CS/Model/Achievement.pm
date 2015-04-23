package CS::Model::Achievement;
use Mojo::Base 'MojoX::Model';

sub verify {
  my ($self, $flag_data, $n) = @_;
  my $db = $self->app->pg->db;

  my $flag = $db->query(
    'select sf.ts, sf.team_id, f.service_id from stolen_flags as sf join flags as f using(data)
    where data = ?', $flag_data
  )->hash;

  # First blood
  $n = $db->query(
    'select count(*) from stolen_flags as sf join flags as f using(data) where sf.ts < ? and service_id = ?',
    $flag->{ts}, $flag->{service_id}
  )->array->[0];
  if ($n == 0) {
    $db->query('insert into achievement (team_id, service_id, data) values (?, ?, ?)',
      $flag->{team_id}, $flag->{service_id}, 'First blood');
  }

  # First flag (team/service)
  $n = $db->query(
    'select count(*)
    from stolen_flags as sf join flags as f using(data)
    where sf.ts < ? and service_id = ? and sf.team_id = ?', $flag->{ts}, $flag->{service_id}, $flag->{team_id}
  )->array->[0];
  if ($n == 0) {
    $db->query('insert into achievement (team_id, service_id, data) values (?, ?, ?)',
      $flag->{team_id}, $flag->{service_id}, 'First flag');
  }

  # N flags (team/service)
  $n = $db->query(
    'select count(*)
    from stolen_flags as sf join flags as f using(data)
    where sf.ts < ? and service_id = ? and sf.team_id = ?', $flag->{ts}, $flag->{service_id}, $flag->{team_id}
  )->array->[0];
  if ($n > 0 && $n % 10 == 0) {
    $db->query('insert into achievement (team_id, service_id, data) values (?, ?, ?)',
      $flag->{team_id}, $flag->{service_id}, "First $n flags");
  }
}

1;
