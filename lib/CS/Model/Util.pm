package CS::Model::Util;
use Mojo::Base 'MojoX::Model';

use List::Util 'min';

sub update_service_phases {
  my ($self, $r) = @_;

  my $app = $self->app;
  my $scoring = $app->config->{cs}{scoring};
  my $db = $app->pg->db;
  my $tx = $db->begin;

  my $active_services = $db->query(q{
    insert into service_activity (round, service_id, phase, active)
    select
      ?, id, 'NOT_RELEASED',
      now() between coalesce(ts_start, '-infinity') and coalesce(ts_end, 'infinity')
    from services
    returning service_id, active
  }, $r)->hashes->reduce(sub { $a->{$b->{service_id}} = $b->{active}; $a }, {});

  for my $service (values %{$app->services}) {
      my $prev_filter = {service_id => $service->{id}, round => $r - 1};
      my $current_filter = {service_id => $service->{id}, round => $r};

      my $prev_phase = $db->select(service_activity => ['phase'], $prev_filter)->array->[0];
      my $prev_base_amount = $db->select(service_activity => ['flag_base_amount'], $prev_filter)->array->[0];
      my ($new_phase, $new_base_amount);

      if (!$active_services->{$service->{id}}) {
        $db->update(service_activity =>
          {phase => $prev_phase, flag_base_amount => $prev_base_amount},
          $current_filter
        );
        next;
      }

      if ($prev_phase eq 'NOT_RELEASED') {
        $new_phase = 'HEATING';
        $new_base_amount = $scoring->{start_flag_price};
      } elsif ($prev_phase eq 'HEATING') {
        my $uniq_submissions = $db->query(q{
          select count(distinct(data))
          from stolen_flags as sf join flags as f using (data)
          where service_id = ?
        }, $service->{id})->array->[0];

        $new_phase = $uniq_submissions >= $scoring->{heating_flags_limit} ? 'COOLING_DOWN' : 'HEATING';

        if ($new_phase eq 'COOLING_DOWN') {
          $new_base_amount = $prev_base_amount * $scoring->{cooling_down};
        } else {
          $new_base_amount = min($prev_base_amount + $scoring->{heating_speed}, $scoring->{max_flag_price});
        }
      } elsif ($prev_phase eq 'COOLING_DOWN') {
        my $cooling_phase = $db->query(q{
          select round, flag_base_amount
          from service_activity
          where service_id = ? and phase = 'COOLING_DOWN'
          order by round limit 1
        }, $service->{id})->hash;

        my $submissions = $db->query(q{
          select count(*)
          from stolen_flags as sf join flags as f using (data)
          where service_id = $1 and sf.round >= $2
        }, $service->{id}, $cooling_phase->{round})->array->[0];

        $new_phase = $submissions >= $scoring->{cooling_submissions_limit} ? 'DYING' : 'COOLING_DOWN';

        if ($new_phase eq 'DYING') {
          $new_base_amount = $scoring->{dying_flag_price};

          # start dying timer
          my $interval = $scoring->{dying_rounds} * $app->round_length - $app->round_length / 2;
          $db->query(q{
            update services
            set ts_end = now() + (interval '1 seconds' * $2::integer)
            where id = $1 and ts_end is null
          }, $service->{id}, $interval);
        } else {
          my $start_amount = $cooling_phase->{flag_base_amount};
          $new_base_amount = $start_amount +
            $submissions * ($scoring->{dying_flag_price} - $start_amount) / $scoring->{cooling_submissions_limit};
        }
      } elsif ($prev_phase eq 'DYING') {
        my $current_dying_rounds = $db->query(q{
          select count(*)
          from service_activity
          where service_id = ? and phase = 'DYING'
        }, $service->{id})->array->[0];

        $new_phase = $current_dying_rounds < $scoring->{dying_rounds} ? 'DYING' : 'REMOVED';
        $new_base_amount = $new_phase eq 'REMOVED' ? 0 : $scoring->{dying_flag_price};
      } elsif ($prev_phase eq 'REMOVED') {
        $new_phase = 'REMOVED';
        $new_base_amount = 0;
      }

      $db->update(service_activity => {phase => $new_phase, flag_base_amount => $new_base_amount}, $current_filter);
  }

  $tx->commit;

  return $active_services;
}

sub get_active_services {
  my $self = shift;

  return $self->app->pg->db->query(q{
    select id, name
    from services
    where now() between coalesce(ts_start, '-infinity') and coalesce(ts_end, 'infinity')
  })->hashes->reduce(sub { $a->{$b->{id}} = $b->{name}; $a }, {});
}

sub get_service_host {
  my ($self, $team, $service) = @_;

  my $host = $team->{host};
  if (my $cb = $self->app->config->{cs}{checkers}{hostname}) {
    $host = $cb->($team, $service)
  }

  return $host;
}

sub game_time {
  my $self = shift;

  my $time = $self->app->config->{cs}{time} // [];
  my ($start, $end) = ($time->[0][0], $time->[-1][1]);

  my $result = $self->app->pg->db->query(q{
    select
      extract(epoch from ?::timestamptz)::float8 as start,
      extract(epoch from ?::timestamptz)::float8 as end
  }, $start, $end)->hash;

  return {start => $result->{start}, end => $result->{end}};
}

sub game_duration {
  my $self = shift;

  my $time = $self->app->config->{cs}{time} // [];
  my $range = join ',', map "'[$_->[0], $_->[1]]'", @$time;

  my $duration = $self->app->pg->db->query(qq{
    select extract(epoch from sum(upper(range)-lower(range)))
    from (select unnest(array[$range]::tstzrange[]) as range) as tmp
  })->array->[0] // 0;

  return $duration / $self->app->round_length;
}

sub game_status {
  my $self = shift;

  my $db = $self->app->pg->db;
  my $time = $self->app->config->{cs}{time};

  return (1, $db->select(rounds => 'max(n)')->array->[0]) unless $time;

  my $range = join ',', map "'[$_->[0], $_->[1]]'", @$time;
  my $sql = <<"SQL";
    with tmp as (
      select *, (select max(n) from rounds where ts < lower(range)) as r
      from (select unnest(array[$range]::tstzrange[]) as range) as tmp
      where lower(range) <= now()
    )
    select
      bool_or(now() <@ range) as live,
      bool_and(now() < lower(range)) as before,
      bool_and(now() > upper(range)) as finish,
      max(r) + 1 as round
    from tmp
SQL
  my $result = $db->query($sql)->hash;

  return -1 if $result->{finish};
  return 0  if $result->{before};
  return (1, $result->{round}) if $result->{live};
  return 0; # break
}

1;
