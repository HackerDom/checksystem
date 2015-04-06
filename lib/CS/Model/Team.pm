package CS::Model::Team;
use Mojo::Base 'MojoX::Model';

sub id_by_address {
  my ($self, $address) = @_;

  if (my $team = $self->app->pg->db->query("select id from teams where ? <<= network", $address)->hash) {
    return $team->{id};
  }
  return undef;
}

1;
