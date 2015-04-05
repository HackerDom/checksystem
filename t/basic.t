use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use CS::Command::manager;

BEGIN { $ENV{MOJO_CONFIG} = 'c_s_test.conf' }

my $t   = Test::Mojo->new('CS');
my $app = $t->app;
my $pg  = $app->pg;

$app->commands->run('reset_db');
$app->commands->run('ensure_db');

my $manager = CS::Command::manager->new(app => $app)->init;
my $ids = $manager->start_round;
$app->minion->perform_jobs;
$manager->finalize_check($app->minion->job($_)) for @$ids;

is $pg->db->query('select count(*) from runs')->array->[0], 8, 'right numbers of runs';

# Down
$pg->db->query('select * from runs where service_id = 1')->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 110, 'right status';
    like $_->{result}{check}{stderr},  qr/Oops/, 'right stderr';
    is $_->{result}{check}{stdout},    '',       'right stdout';
    is $_->{result}{check}{exception}, '',       'right exception';
    is $_->{result}{check}{timeout},   0,        'right timeout';
    is keys %{$_->{result}{put}},   0, 'right put';
    is keys %{$_->{result}{get_1}}, 0, 'right get_1';
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

# Up
$pg->db->query('select * from runs where service_id = 2')->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 101, 'right status';
    for my $step (qw/check put get_1/) {
      is $_->{result}{$step}{stderr},    '', 'right stderr';
      is $_->{result}{$step}{stdout},    '', 'right stdout';
      is $_->{result}{$step}{exception}, '', 'right exception';
      is $_->{result}{$step}{timeout},   0,  'right timeout';
    }
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

# Timeout
$pg->db->query('select * from runs where service_id = 4')->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 110, 'right status';
    is $_->{result}{check}{stderr},      '',           'right stderr';
    is $_->{result}{check}{stdout},      '',           'right stdout';
    like $_->{result}{check}{exception}, qr/timeout/i, 'right exception';
    is $_->{result}{check}{timeout},     1,            'right timeout';
    is keys %{$_->{result}{put}},   0, 'right put';
    is keys %{$_->{result}{get_1}}, 0, 'right get_1';
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

# Flags
is $pg->db->query('select count(*) from flags')->array->[0], 2, 'right numbers of flags';
$pg->db->query('select * from flags')->hashes->map(
  sub {
    is $_->{round},  1,                                    'right round';
    like $_->{id},   qr/[a-z\d]{4}-[a-z\d]{4}-[a-z\d]{4}/, 'right id';
    like $_->{data}, qr/[A-Z\d]{31}=/,                     'right flag';
  }
);

done_testing;
