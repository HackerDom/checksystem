package CS::Command::recalc;
use Mojo::Base 'Mojolicious::Command';

has description => 'Recalc scores';

use Mojo::Promise;
use List::Util 'min';

# once
# for my $table ('sla', 'flag_points', 'scores', 'scoreboard', 'stolen_flags', 'flags', 'rounds') {
#   $db->query("drop table if exists ${table}_origin");
#   $db->query("create table ${table}_origin as (select * from $table)");
# }

# alter table flag_points drop constraint flag_points_round_fkey;
# alter table sla drop constraint sla_round_fkey;
# alter table flags drop constraint flags_round_fkey;
# alter table stolen_flags drop constraint stolen_flags_round_fkey;
# alter table scores drop constraint scores_round_fkey;
# alter table service_activity drop constraint service_activity_round_fkey;
# alter table monitor drop constraint monitor_round_fkey;
# alter table runs drop constraint runs_round_fkey;
# alter table scoreboard drop constraint scoreboard_round_fkey;

# alter table service_activity add column flag_base_amount float8 not null default 0;
# alter table service_activity add column phase service_phase not null;
# create type service_phase as enum ('NOT_RELEASED', 'HEATING', 'COOLING_DOWN', 'DYING', 'REMOVED');

sub run {
  my $self = shift;
  my $app  = $self->app;
  my $db = $app->pg->db;

  # cleanup
  for my $table ('sla', 'flag_points', 'scores', 'scoreboard', 'stolen_flags', 'service_activity', 'rounds') {
    $db->query("truncate $table");
  }

  # init
  $db->insert(rounds => {n => 0});
  $db->query(q{
    insert into service_activity (round, service_id, active, phase)
    select 0, id, false, 'NOT_RELEASED' from services
  });
  $db->query('
    insert into flag_points (round, team_id, service_id, amount)
    select 0, teams.id, services.id, 1 from teams cross join services
  ');
  $db->query('
    insert into sla (round, team_id, service_id, successed, failed)
    select 0, teams.id, services.id, 0, 0 from teams cross join services
  ');
  $app->model('score')->scoreboard($db, 0);

  my $rounds = $db->select(rounds_origin => 'max(n)')->array->[0];
  for my $r (1 .. $rounds) {
    $db->insert('rounds', {n => \'(select max(n)+1 from rounds)'});
    $app->log->info("Recalc round $r");

    my $active_services = $app->model('util')->update_service_phases($r);

    # post flags
    my $flags = $db->select('stolen_flags_origin', ['team_id', 'data'], {round => $r})->hashes;
    $app->log->info("Stolen flags: " . (0 + @$flags));

    if (@$flags) {
      my $post = Mojo::Promise->map({concurrency => 8}, sub {

        my $p = Mojo::Promise->new;
        $app->model('flag')->accept($_->{team_id}, $_->{data}, sub {
          $p->resolve($_[0])
        });
        return $p;

      }, @$flags);

      $post->wait;
    }

    # calc scores
    $app->model('score')->update($r);
  }
}

1;
