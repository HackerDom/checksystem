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

# create table scoreboard_sla3gf10 as (select * from scoreboard);
# create table scores_sla3gf10 as (select * from scores);
# create table flag_points_sla3gf10 as (select * from flag_points);
# create table sla_sla3gf10 as (select * from sla);

# alter table flag_points drop constraint flag_points_round_fkey;
# alter table sla drop constraint sla_round_fkey;
# alter table flags drop constraint flags_round_fkey;
# alter table stolen_flags drop constraint stolen_flags_round_fkey;
# alter table scores drop constraint scores_round_fkey;
# alter table service_activity_log drop constraint service_activity_log_round_fkey;
# alter table monitor drop constraint monitor_round_fkey;
# alter table runs drop constraint runs_round_fkey;
# alter table scoreboard drop constraint scoreboard_round_fkey;

# alter table flags add column amount float8;
# alter table service_activity_log add column flag_base_amount float8;
# alter table service_activity_log add column phase service_phase;
# create type service_phase as enum ('NOT_RELEASED', 'HEATING', 'COOLING_DOWN', 'DYING', 'REMOVED');

my $start_flag_price = 10;
my $heating_speed = 1/12;
my $max_flag_price = 30;
my $cooling_down = 1/2;
my $heating_flags_limit = 20 * 20; # 20 * teams_count
my $cooling_submissions_limit = 500 * 20; # 500 * teams_count
my $dying_rounds = 120;
my $dying_flag_price = 1;

sub run {
  my $self = shift;
  my $app  = $self->app;
  my $db = $app->pg->db;

  # cleanup
  for my $table ('sla', 'flag_points', 'scores', 'scoreboard', 'stolen_flags', 'rounds') {
    $db->query("truncate $table");
  }
  $db->query("update service_activity_log set phase = null, flag_base_amount = null");
  $db->query("
    update service_activity_log
    set phase = case when active then 'HEATING'::service_phase else 'NOT_RELEASED'::service_phase end,
        flag_base_amount = $start_flag_price
    where round = 0
  ");

  # init
  $db->insert(rounds => {n => 0});
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

    for my $service (values %{$app->services}) {

      my $current_phase;
      my $prev_phase = $db->select(
        service_activity_log => ['phase'], {service_id => $service->{id}, round => $r - 1}
      )->hash->{phase};
      my $prev_base_amount = $db->select(
        service_activity_log => ['flag_base_amount'], {service_id => $service->{id}, round => $r - 1}
      )->hash->{flag_base_amount};
      my $current_base_amount = $prev_base_amount;

      my $is_service_active = $db->select(
        service_activity_log => ['active'], {service_id => $service->{id}, round => $r}
      )->hash->{active};

      if (!$is_service_active || $prev_phase eq 'REMOVED') {
        $db->update(
          'service_activity_log',
          {phase => $prev_phase, flag_base_amount => $prev_base_amount},
          {service_id => $service->{id}, round => $r}
        );
        next;
      }

      if ($prev_phase eq 'NOT_RELEASED') {
        $current_phase = 'HEATING';
      } elsif ($prev_phase eq 'HEATING') {

        my $sql = <<'SQL';
          select count(distinct(data))
          from stolen_flags as sf join flags as f using (data)
          where service_id = $1 and sf.round < $2
SQL
        my $uniq_flags_submissions = $db->query($sql, $service->{id}, $r)->array->[0];

        $current_phase = $uniq_flags_submissions <= $heating_flags_limit ? 'HEATING' : 'COOLING_DOWN';
      } elsif ($prev_phase eq 'COOLING_DOWN') {
        my $cooling_phase_start = $db->query("
          select round
          from service_activity_log
          where service_id = ? and phase = 'COOLING_DOWN'
          order by round limit 1
        ", $service->{id})->array->[0];

        my $sql = <<'SQL';
          select count(*)
          from stolen_flags as sf join flags as f using (data)
          where service_id = $1 and sf.round >= $2 and sf.round < $3
SQL
        my $flags_submissions = $db->query($sql, $service->{id}, $cooling_phase_start, $r)->array->[0];

        $current_phase = $flags_submissions >= $cooling_submissions_limit ? 'DYING' : 'COOLING_DOWN';
      } elsif ($prev_phase eq 'DYING') {

        my $sql = <<'SQL';
          select count(*)
          from service_activity_log
          where service_id = $1 and phase = 'DYING'
SQL
        my $current_dying_rounds = $db->query($sql, $service->{id})->array->[0];

        $current_phase = $current_dying_rounds < $dying_rounds ? 'DYING' : 'REMOVED';
      }

      $db->update('service_activity_log', {phase => $current_phase}, {service_id => $service->{id}, round => $r});

      if ($current_phase eq 'HEATING') {
        $current_base_amount = min($current_base_amount + $heating_speed, $max_flag_price);
      } elsif ($current_phase eq 'COOLING_DOWN' && $prev_phase eq 'HEATING') {
        $current_base_amount *= $cooling_down;
      } elsif ($current_phase eq 'COOLING_DOWN' && $prev_phase eq 'COOLING_DOWN') {
        my $cooling_phase = $db->query("
          select round, flag_base_amount as a
          from service_activity_log
          where service_id = ? and phase = 'COOLING_DOWN'
          order by round limit 1
        ", $service->{id})->hash;
        my $sql = <<'SQL';
          select count(*)
          from stolen_flags as sf join flags as f using (data)
          where service_id = $1 and sf.round >= $2 and sf.round < $3
SQL
        my $flags_submissions = $db->query($sql, $service->{id}, $cooling_phase->{round}, $r)->array->[0];
        $current_base_amount = $cooling_phase->{a} + $flags_submissions * ($dying_flag_price - $cooling_phase->{a}) / $cooling_submissions_limit;
      } elsif ($current_phase eq 'DYING') {
        $current_base_amount = $dying_flag_price;
      }

      $db->update('service_activity_log', {flag_base_amount => $current_base_amount}, {service_id => $service->{id}, round => $r});
    }

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
