package CS::Model::Util;
use Mojo::Base 'MojoX::Model';

sub team_id_by_address {
  my ($self, $address) = @_;

  my $team = $self->app->pg->db->query("select id from teams where ? <<= network", $address)->hash;
  return $team ? $team->{id} : undef;
}

sub ensure_active_services {
  my $self = shift;

  $self->app->pg->db->query(q{
    insert into service_activity_log (round, service_id, active)
    select
      (select max(n) from rounds), id,
      now() between coalesce(ts_start, '-infinity') and coalesce(ts_end, 'infinity')
    from services
    returning service_id, active
  })->hashes->reduce(sub { $a->{$b->{service_id}} = $b->{active}; $a }, {});
}

sub get_active_services {
  my $self = shift;

  return $self->app->pg->db->query(q{
    select id
    from services
    where now() between coalesce(ts_start, '-infinity') and coalesce(ts_end, 'infinity')
  })->hashes->reduce(sub { $a->{$b->{id}}++; $a }, {});
}

sub game_time {
  my $self = shift;

  my $time = $self->app->config->{cs}{time};
  my ($start, $end) = ($time->[0][0], $time->[-1][1]);

  my $result = $self->app->pg->db->query('
    select extract(epoch from ?::timestamptz) as start, extract(epoch from ?::timestamptz) as end
  ', $start, $end)->hash;

  return {start => $result->{start}, end => $result->{end}};
}

sub game_status {
  my $self = shift;

  my $time = $self->app->config->{cs}{time};
  my ($start, $finish) = ($time->[0][0], $time->[-1][1]);

  my $range = join ',', map "'[$_->[0], $_->[1]]'", @$time;
  my $sql = <<"SQL";
    select
      bool_or(now() <@ range) as live,
      bool_and(now() < lower(range)) as before,
      bool_and(now() > upper(range)) as finish
    from (select unnest(array[$range]::tstzrange[]) as range) as tmp
SQL
  my $result = $self->app->pg->db->query($sql)->hash;

  return -1 if $result->{finish};
  return 0  if $result->{before};
  return 1  if $result->{live};
  return 0; # break
}

1;
