use Mojo::Base -strict;

use Test::Mojo;
use Test::More;
use Time::Piece;

BEGIN { $ENV{MOJO_CONFIG} = 'cs.test.conf' }

my $t   = Test::Mojo->new('CS');
my $app = $t->app;

# game status
my $u = $app->model('util');
my $f = $u->format;
is $u->game_status(0 + localtime(Time::Piece->strptime('2012-10-24 13:00:00', $f))), 0,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2013-01-01 00:00:00', $f))), 1,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2013-01-01 00:00:01', $f))), 1,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2015-01-01 00:00:00', $f))), 1,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2016-01-01 00:00:00', $f))), 1,  'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2029-01-01 00:00:00', $f))), -1, 'right status';

# break
$app->config->{cs}{time}{break} = ['2014-01-01 00:00:00', '2015-01-01 00:00:00'];
is $u->game_status(0 + localtime(Time::Piece->strptime('2014-01-01 00:00:00', $f))), 0, 'right status';
is $u->game_status(0 + localtime(Time::Piece->strptime('2014-12-31 23:59:59', $f))), 0, 'right status';
delete $app->config->{cs}{time}{break};
is $u->game_status(0 + localtime(Time::Piece->strptime('2014-01-01 00:00:00', $f))), 1, 'right status';

# id by address
is $u->team_id_by_address('127.0.2.213'),  2,     'right id';
is $u->team_id_by_address('127.0.23.127'), undef, 'right id';

done_testing;
