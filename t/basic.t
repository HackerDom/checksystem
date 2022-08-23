use Mojo::Base -strict;

use Test::Mojo;
use Test::More;

use Mojo::Collection 'c';

use CS::Command::manager;

BEGIN { $ENV{MOJO_CONFIG} = 'cs.test.conf' }

my $t   = Test::Mojo->new('CS');
my $app = $t->app;
my $db  = $app->pg->db;

diag('Init');

$app->commands->run('reset_db');
$app->commands->run('init_db');
$app->init;

my $up1 = $db->select(services => '*', {name => 'up1'})->hash;
is $up1->{vulns}, '1:1:2', 'right vulns';
is $up1->{public_flag_description}, 'user profile', 'right flag description in db';
is $app->services->{3}{public_flag_description}, 'user profile', 'right flag description in app';

is_deeply $app->teams->{1}{tags}, ['edu', 'online', 'Russia'], 'right tags for team';

my $manager = CS::Command::manager->new(app => $app);

diag('New round #1');

# Disable up2
$db->update('services', {ts_start => \"now() + interval '10 minutes'", ts_end => undef}, {name => 'up2'});

$manager->start_round;
is $manager->round, 1, 'right round';
$app->minion->perform_jobs({queues => ['default', 'checker', 'checker-1', 'checker-2']});
$app->model('score')->update;

# Runs (3 avtive services * 3 teams)
is $db->query('select count(*) from runs')->array->[0], 12, 'right numbers of runs';

# Service down1
$db->select(runs => '*', {service_id => 1, team_id => 1})->expand->hashes->map(
  sub {
    is $_->{round},  1,               'right round';
    is $_->{status}, 104,             'right status';
    is $_->{stdout}, "some error!\n", 'right stdout';
  }
);

# Service down2
$db->select(runs => '*', {service_id => 2, team_id => 1})->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 104, 'right status';
    is $_->{stdout}, '',  'right stdout';
    my $result = $_->{result};
    my $state = c(qw/get_2 get_1 put check/)->first(sub { defined $result->{$_}{exception} });
    is $_->{result}{$state}{stderr},      '',           'right stderr';
    is $_->{result}{$state}{stdout},      '',           'right stdout';
    like $_->{result}{$state}{exception}, qr/timeout/i, 'right exception';
    is $_->{result}{$state}{timeout},     1,            'right timeout';
  }
);

# Service up1
$db->select(runs => '*', {service_id => 3, team_id => 1})->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 101, 'right status';
    is $_->{stdout}, '',  'right stdout';
    for my $step (qw/check put get_1/) {
      is $_->{result}{$step}{stderr},    '',                                             'right stderr';
      is $_->{result}{$step}{stdout},    '{"public_flag_id":"911","password":"sEcr3t"}', 'right stdout';
      is $_->{result}{$step}{exception}, '',                                             'right exception';
      is $_->{result}{$step}{timeout},   0,                                               'right timeout';
    }
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
  }
);

# Service up2
$db->select(runs => '*', {service_id => 4, team_id => 1})->expand->hashes->map(
  sub {
    is $_->{round},  1,   'right round';
    is $_->{status}, 111, 'right status';
    is $_->{stdout}, undef,  'right stdout';
    is keys %{$_->{result}{check}},   0, 'right check';
    is keys %{$_->{result}{put}},   0, 'right put';
    is keys %{$_->{result}{get_1}}, 0, 'right get_1';
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
    is keys %{$_->{result}{get_2}}, 0, 'right get_2';
    like $_->{result}{error}, qr/Service was disabled/i, 'right error';
  }
);

diag('SLA after #1');
is $db->query('select count(*) from sla')->array->[0], 12, 'right sla';

diag('FP after #1');
is $db->query('select count(*) from flag_points')->array->[0], 12, 'right fp';

# Flags (only for service up1)
is $db->query('select count(*) from flags where ack = true')->array->[0], 3, 'right numbers of flags';
$db->query('select * from flags where ack = true')->hashes->map(
  sub {
    is $_->{round},     1,                                              'right round';
    is $_->{id},        '{"public_flag_id":"911","password":"sEcr3t"}', 'right id';
    is $_->{public_id}, '911',                                          'right public id';
    like $_->{data},    qr/TEAM\d{3}_[A-Z0-9]{32}/,                     'right flag';
  }
);

# Enable up2
$db->update('services', {ts_start => undef, ts_end => undef}, {name => 'up2'});

diag('New round #2');
$manager->start_round;
is $manager->round, 2, 'right round';
$app->minion->perform_jobs({queues => ['default', 'checker', 'checker-1', 'checker-2']});
$app->model('score')->update;

my $value = $app->model('scoreboard')->generate;
if ($value->{round} == 1) {
  my $team1 = $value->{scoreboard}[0];
  is $team1->{team_id}, 1, 'right scoreboard api';
  is $team1->{round}, 1, 'right scoreboard api';
  is $team1->{services}[3]{status}, 111, 'right scoreboard api';

  is $value->{services}{1}{active}, 1, 'right scoreboard api';
  is $value->{services}{1}{name}, 'down1', 'right scoreboard api';

  is $value->{services}{4}{active}, 0, 'right scoreboard api';
  is $value->{services}{4}{name}, 'up2', 'right scoreboard api';
}

my ($data, $flag_data);
my $flag_cb = sub { $data = $_[0] };

diag('Flags after #2');
$db->update('services', {ts_start => \"now() + interval '10 minutes'", ts_end => undef}, {name => 'up2'});
$flag_data = $db->select(flags => 'data', {team_id => 1, service_id => 4, ack => 'true'})->hash->{data};
$app->model('flag')->accept(2, $flag_data, $flag_cb);
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/service inactive/, 'right error';
$db->update('services', {ts_start => undef, ts_end => undef}, {name => 'up2'});

$app->model('flag')->accept(2, 'flag', $flag_cb);
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/invalid or own flag/, 'right error';

$flag_data = $db->select(flags => 'data', {team_id => 2, ack => 'true'})->hash->{data};
$app->model('flag')->accept(2, $flag_data, $flag_cb);
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/invalid or own flag/, 'right error';

$flag_data = $db->select(flags => 'data', {team_id => 1, ack => 'true'})->hash->{data};
$app->model('flag')->accept(2, $flag_data, $flag_cb);
is $data->{ok}, 1, 'right status';
my $stolen_flag = $db->select(stolen_flags => undef, {team_id => 2})->hash;
is $stolen_flag->{data}, $flag_data, 'right flag';
is $stolen_flag->{amount}, $app->config->{cs}{scoring}{start_flag_price}, 'right amount';

$app->model('flag')->accept(2, $flag_data, $flag_cb);
is $data->{ok}, 0, 'right status';
like $data->{error}, qr/you already submitted this flag/, 'right error';

diag('SLA after #2');
is $db->query('select count(*) from sla')->array->[0], 24, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 1, round => 1})->hash; # down1
is $data->{successed}, 0, 'right sla';
is $data->{failed},    1, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 2, round => 1})->hash; # down2
is $data->{successed}, 0, 'right sla';
is $data->{failed},    1, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 3, round => 1})->hash; # up1
is $data->{successed}, 1, 'right sla';
is $data->{failed},    0, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 4, round => 1})->hash; # up2
is $data->{successed}, 0, 'right sla';
is $data->{failed},    0, 'right sla';

diag('FP after #2');
is $db->query('select count(*) from flag_points')->array->[0], 24, 'right fp';
$db->query('select * from flag_points where round = 1')->hashes->map(sub { is $_->{amount}, 0, 'right fp' });

diag('New round #3');
$manager->start_round;
is $manager->round, 3, 'right round';
$app->minion->perform_jobs({queues => ['default', 'checker', 'checker-1', 'checker-2']});
$app->model('score')->update;

diag('Flags after #3');
$flag_data = $db->select(flags => 'data', {team_id => 1, ack => 'true', round => 2})->hash->{data};
$app->model('flag')->accept(2, $flag_data, $flag_cb);
is $data->{ok}, 1, 'right status';
$stolen_flag = $db->select(stolen_flags => undef, {team_id => 2, round => 3})->hash;
is $stolen_flag->{data}, $flag_data, 'right flag';
ok $stolen_flag->{amount} > $app->config->{cs}{scoring}{start_flag_price}, 'right amount';

diag('SLA after #3');
is $db->query('select count(*) from sla')->array->[0], 36, 'right sla';

$data = $db->select(sla => '*', {team_id => 1, service_id => 1, round => 2})->hash; # down1
is $data->{successed}, 0, 'right sla';
is $data->{failed},    2, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 2, round => 2})->hash; # down2
is $data->{successed}, 0, 'right sla';
is $data->{failed},    2, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 3, round => 2})->hash; # up1
is $data->{successed}, 2, 'right sla';
is $data->{failed},    0, 'right sla';
$data = $db->select(sla => '*', {team_id => 1, service_id => 4, round => 2})->hash; # up2
is $data->{successed}, 1, 'right sla';
is $data->{failed},    0, 'right sla';

diag('FP after #3');
is $db->query('select count(*) from flag_points')->array->[0], 36, 'right fp';

diag('New round #4');
$manager->start_round;
is $manager->round, 4, 'right round';
$app->minion->perform_jobs({queues => ['default', 'checker', 'checker-1', 'checker-2']});
$app->model('score')->update;

$app->model('score')->update(4);

# API
$t->get_ok('/api/info')
  ->json_has('/start')
  ->json_has('/end')
  ->json_has('/services')
  ->json_has('/teams')
  ->json_has('/teams/1/id')
  ->json_has('/teams/1/name')
  ->json_has('/teams/1/host')
  ->json_has('/teams/1/network')
  ->json_has('/teams/1/tags');

$t->get_ok('/teams')
  ->json_has('/1')
  ->json_is('/1/id', '1')
  ->json_is('/1/name', 'team1')
  ->json_is('/1/network', '127.0.1.0/24');

$t->get_ok('/services')
  ->json_is('/1', 'down1')
  ->json_is('/2', 'down2')
  ->json_is('/3', 'up1')
  ->json_is('/4', 'up2');

$t->get_ok('/flag_ids?service_id=3' => {'X-Team-Token' => $app->teams->{1}{token}})
  ->json_is('/flag_id_description', $app->services->{3}{public_flag_description})
  ->json_has('/flag_ids/2/flag_ids/0')
  ->json_has('/flag_ids/2/host')
  ->json_has('/flag_ids/3/flag_ids/0')
  ->json_has('/flag_ids/3/host');

$t->get_ok('/scoreboard.json')
  ->json_has('/round')
  ->json_has('/scoreboard')
  ->json_has('/scoreboard/0/d')
  ->json_has('/scoreboard/0/round')
  ->json_has('/scoreboard/0/host')
  ->json_has('/scoreboard/0/network')
  ->json_has('/scoreboard/0/team_id')
  ->json_has('/scoreboard/0/score')
  ->json_has('/scoreboard/0/old_score')
  ->json_has('/scoreboard/0/n')
  ->json_has('/scoreboard/0/name')
  ->json_has('/scoreboard/0/services')
  ->json_has('/scoreboard/0/old_services')
  ->json_has('/scoreboard/0/services/0/stdout')
  ->json_has('/scoreboard/0/services/0/id')
  ->json_has('/scoreboard/0/services/0/sflags')
  ->json_has('/scoreboard/0/services/0/flags')
  ->json_has('/scoreboard/0/services/0/sla')
  ->json_has('/scoreboard/0/services/0/fp')
  ->json_has('/scoreboard/0/services/0/status');

$t->get_ok('/history/scoreboard.json')
  ->json_has('/0/round')
  ->json_has('/0/scoreboard')
  ->json_has('/0/scoreboard/0/id')
  ->json_has('/0/scoreboard/0/score')
  ->json_has('/0/scoreboard/0/services')
  ->json_has('/0/scoreboard/0/services/0/sflags')
  ->json_has('/0/scoreboard/0/services/0/flags')
  ->json_has('/0/scoreboard/0/services/0/fp')
  ->json_has('/0/scoreboard/0/services/0/status');

$t->get_ok('/ctftime/scoreboard.json')
  ->json_has('/standings')
  ->json_has('/standings/0/pos')
  ->json_has('/standings/0/team')
  ->json_has('/standings/0/score');

$t->get_ok('/ctftime/fb.json');

done_testing;
