package CS::Model::Flag;
use Mojo::Base 'MojoX::Model';

use String::Random 'random_regex';

sub create {
  return {
    id   => join('-', map random_regex('[a-z0-9]{4}'), 1 .. 3),
    data => random_regex('[A-Z0-9]{31}') . '='
  };
}

1;
