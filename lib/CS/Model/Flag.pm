package CS::Model::Flag;
use Mojo::Base 'MojoX::Model';

use String::Random 'random_regex';

has format => '[A-Z0-9]{31}=';

sub create {
  return {id => join('-', map random_regex('[a-z0-9]{4}'), 1 .. 3), data => random_regex($self->format)};
}

sub accept {
  my ($self, $team_id, $flag_data) = @_;
  my $app = $self->app;
  my $db  = $app->pg->db;

  my $flag = $db->query('select team_id, service_id, round from flags where data = ?', $flag_data)->hash;
  return {ok => 0, error => 'Denied: no such flag'} unless $flag;
  return {ok => 0, error => 'Denied: flag is your own'} if $flag->{team_id} == $team_id;
  return {ok => 0, error => 'Denied: you already submitted this flag'}
    if $db->query('select * from stolen_flags where data = ? and team_id = ?', $flag_data, $team_id)->rows;
  return {ok => 0, error => 'Denied: flag is too old'}
    if $flag->{round} <=
    $db->query('select max(n) from rounds')->array->[0] - $app->config->{cs}{flag_life_time};

  if ($db->query('insert into stolen_flags (data, team_id) values (?, ?)', $flag_data, $team_id)->rows) {
    return {ok => 1};
  } else {
    return {ok => 0, error => 'Please try again later'};
  }
}

1;
