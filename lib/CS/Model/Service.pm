package CS::Model::Service;
use Mojo::Base 'MojoX::Model';

sub update_irrelevant {
  my $self = shift;
  my $db = $self->app->pg->db;

  my $sql = <<SQL;
    with tmp as (
      select service_id, sf.team_id, count(*)
      from stolen_flags as sf join flags as f using(data)
      group by service_id, sf.team_id
      having count(*) >= 1000
    )
    select service_id
    from tmp
    group by service_id
    having count(*) >= 5
SQL
  my $services = $db->query($sql)->arrays->flatten->to_array;

  my $updates_services = $db->update(services =>
    {ts_end => \"now() + interval '1 hour'"},
    {id => $services, ts_end => undef},
    {returning => 'id'}
  )->arrays->flatten->to_array;
  $self->app->log->info("Enqueue services to remove: @{$updates_services}");
}

1;
