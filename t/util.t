use Mojo::Base -strict;

use Test::Mojo;
use Test::More;

BEGIN { $ENV{MOJO_CONFIG} = 'cs.test.conf' }

my $t   = Test::Mojo->new('CS');
my $app = $t->app;
my $u = $app->model('util');

# game status
my $status = $u->game_status;
$status >= 0 ? pass('right status') : fail('right status');

my $game_time = $u->game_time;
ok $game_time->{start} > 0, 'right game time';
ok $game_time->{end} > 0, 'right game time';

# id by address
is $u->team_id_by_address('127.0.2.213'),  2,     'right id';
is $u->team_id_by_address('127.0.23.127'), undef, 'right id';

done_testing;
