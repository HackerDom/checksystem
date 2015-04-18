package CS::Model::Util;
use Mojo::Base 'MojoX::Model';

sub team_id_by_address {
  my ($self, $address) = @_;

  my $team = $self->app->pg->db->query("select id from teams where ? <<= network", $address)->hash;
  return $team ? $team->{id} : undef;
}

1;
