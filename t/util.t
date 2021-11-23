use Mojo::Base -strict;

use Test::Mojo;
use Test::More;

BEGIN { $ENV{MOJO_CONFIG} = 'cs.test.conf' }

my $t   = Test::Mojo->new('CS');
my $app = $t->app;
my $u = $app->model('util');

# game status
my ($status, $round) = $u->game_status;
$status >= 0 ? pass('right status') : fail('right status');

my $game_time = $u->game_time;
ok $game_time->{start} > 0, 'right game time';
ok $game_time->{end} > 0, 'right game time';

ok $u->game_duration > 0, 'rigth game duration';

done_testing;
