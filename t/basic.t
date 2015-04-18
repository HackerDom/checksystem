use Mojo::Base -strict;

use Test::Mojo;
use Test::More;
use Time::Piece;

use CS::Command::manager;

BEGIN { $ENV{MOJO_CONFIG} = 'c_s_test.conf' }

my $t   = Test::Mojo->new('CS');
my $app = $t->app;
my $db  = $app->pg->db;

$app->commands->run('reset_db');
$app->commands->run('ensure_db');

my ($u, $format) = ($app->model('util'), '%Y-%m-%d %H:%M:%S');
is $u->game_status(Time::Piece->strptime('2012-10-24 13:00:00', $format)), 0,  'right status';
is $u->game_status(Time::Piece->strptime('2013-01-01 00:00:00', $format)), 1,  'right status';
is $u->game_status(Time::Piece->strptime('2013-01-01 00:00:01', $format)), 1,  'right status';
is $u->game_status(Time::Piece->strptime('2014-01-01 00:00:00', $format)), 0,  'right status';
is $u->game_status(Time::Piece->strptime('2014-12-31 23:59:59', $format)), 0,  'right status';
is $u->game_status(Time::Piece->strptime('2015-01-01 00:00:00', $format)), 1,  'right status';
is $u->game_status(Time::Piece->strptime('2016-01-01 00:00:00', $format)), 1,  'right status';
is $u->game_status(Time::Piece->strptime('2019-01-01 00:00:00', $format)), -1, 'right status';

is $u->team_id_by_address('127.0.2.213'),  2,     'right id';
is $u->team_id_by_address('127.0.23.127'), undef, 'right id';

my $manager = CS::Command::manager->new(app => $app);

# New round (#1)
my $ids = $manager->start_round;
is $manager->round, 1, 'right round';
$app->minion->perform_jobs;
$manager->finalize_check($app->minion->job($_)) for @$ids;

# Runs
is $db->query('select count(*) from runs')->array->[0], 8, 'right numbers of runs';

# Down
$db->query('select * from runs where service_id = 1')->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 104, 'right status';
    is $_->{result}{check}{stderr},    '', 'right stderr';
    is $_->{result}{check}{stdout},    '', 'right stdout';
    is $_->{result}{check}{exception}, '', 'right exception';
    is $_->{result}{check}{timeout},   0,  'right timeout';
    is keys %{$_->{result}{put}},   0, 'right put';
    is keys %{$_->{result}{get_1}}, 0, 'right get_1';
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

# Up
$db->query('select * from runs where service_id = 2')->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 101, 'right status';
    for my $step (qw/check put get_1/) {
      is $_->{result}{$step}{stderr},    '',  'right stderr';
      is $_->{result}{$step}{stdout},    911, 'right stdout';
      is $_->{result}{$step}{exception}, '',  'right exception';
      is $_->{result}{$step}{timeout},   0,   'right timeout';
    }
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

# Timeout
$db->query('select * from runs where service_id = 4')->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 104, 'right status';
    is $_->{result}{check}{stderr},      '',           'right stderr';
    is $_->{result}{check}{stdout},      '',           'right stdout';
    like $_->{result}{check}{exception}, qr/timeout/i, 'right exception';
    is $_->{result}{check}{timeout},     1,            'right timeout';
    is keys %{$_->{result}{put}},   0, 'right put';
    is keys %{$_->{result}{get_1}}, 0, 'right get_1';
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

my ($data, $flag_data);

# SLA
$app->model('score')->sla;
is $db->query('select count(*) from sla')->array->[0], 8, 'right sla';

# FP
$app->model('score')->flag_points;
is $db->query('select count(*) from score')->array->[0], 8, 'right score';
for my $team_id (1, 2) {
  $data = $db->query("select * from score where team_id = $team_id and service_id = 2 and round = 0")->hash;
  is $data->{score}, 200, 'right score';
  $data = $db->query("select * from score where team_id = $team_id and service_id = 1 and round = 0")->hash;
  is $data->{score}, 200, 'right score';
}

# Flags
is $db->query('select count(*) from flags')->array->[0], 2, 'right numbers of flags';
$db->query('select * from flags')->hashes->map(
  sub {
    is $_->{round},  1,                'right round';
    is $_->{id},     911,              'right id';
    like $_->{data}, qr/[A-Z\d]{31}=/, 'right flag';
  }
);

$data = $app->model('flag')->accept(2, 'flag');
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/no such flag/, 'right error';

$flag_data = $db->query('select data from flags where team_id = 2 limit 1')->hash->{data};
$data = $app->model('flag')->accept(2, $flag_data);
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/flag is your own/, 'right error';

$flag_data = $db->query('select data from flags where team_id = 1 limit 1')->hash->{data};
$data = $app->model('flag')->accept(2, $flag_data);
is $data->{ok}, 1, 'right status';
is $db->query('select data from stolen_flags where team_id = 2 and victim_team_id = 1 limit 1')->hash->{data},
  $flag_data, 'right flag';

$data = $app->model('flag')->accept(2, $flag_data);
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/you already submitted this flag/, 'right error';

# New round (#2)
$ids = $manager->start_round;
is $manager->round, 2, 'right round';
$app->minion->perform_jobs;
$manager->finalize_check($app->minion->job($_)) for @$ids;

# SLA
$app->model('score')->sla;
is $db->query('select count(*) from sla')->array->[0], 16, 'right sla';
for my $team_id (1, 2) {
  $data = $db->query("select * from sla where team_id = $team_id and service_id = 2 and round = 1")->hash;
  is $data->{successed}, 1, 'right sla';
  is $data->{failed},    0, 'right sla';
  $data = $db->query("select * from sla where team_id = $team_id and service_id = 1 and round = 1")->hash;
  is $data->{successed}, 0, 'right sla';
  is $data->{failed},    1, 'right sla';
}

# FP
$app->model('score')->flag_points;
is $db->query('select count(*) from score')->array->[0], 8, 'right score';
for my $team_id (1, 2) {
  $data = $db->query("select * from score where team_id = $team_id and service_id = 2 and round = 0")->hash;
  is $data->{score}, 200, 'right score';
  $data = $db->query("select * from score where team_id = $team_id and service_id = 1 and round = 0")->hash;
  is $data->{score}, 200, 'right score';
}

# New round (#3)
$ids = $manager->start_round;
is $manager->round, 3, 'right round';
$app->minion->perform_jobs;
$manager->finalize_check($app->minion->job($_)) for @$ids;

# SLA
$app->model('score')->sla;
is $db->query('select count(*) from sla')->array->[0], 24, 'right sla';
for my $team_id (1, 2) {
  $data = $db->query("select * from sla where team_id = $team_id and service_id = 2 and round = 2")->hash;
  is $data->{successed}, 2, 'right sla';
  is $data->{failed},    0, 'right sla';
  $data = $db->query("select * from sla where team_id = $team_id and service_id = 1 and round = 2")->hash;
  is $data->{successed}, 0, 'right sla';
  is $data->{failed},    2, 'right sla';
  $data = $db->query("select * from sla where team_id = $team_id and service_id = 3 and round = 2")->hash;
  is $data->{successed} + $data->{failed}, 2, 'right sla';
}

# FP
$app->model('score')->flag_points;
is $db->query('select count(*) from score')->array->[0], 16, 'right score';
is $db->query("select score from score where team_id = 2 and service_id = 2 and round = 1")->array->[0], 202,
  'right score';
is $db->query("select score from score where team_id = 1 and service_id = 2 and round = 1")->array->[0], 198,
  'right score';
for my $team_id (1, 2) {
  $data = $db->query("select * from score where team_id = $team_id and service_id = 1 and round = 1")->hash;
  is $data->{score}, 200, 'right score';
}

$db->query('refresh materialized view scoreboard');

done_testing;
