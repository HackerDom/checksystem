package CS::Command::status;
use Mojo::Base 'Mojolicious::Command';

has description => 'Get status';

sub run {
  my $self = shift;
  my $app  = $self->app;
  my $db   = $app->pg->db;

  my $stats = $app->minion->stats;

  my @percentile = (0.5, 0.75, 0.9, 0.99);
  my $result = $db->query(
    q{
    select
      percentile_disc($1::float[]) within group (order by latency) as latency,
      percentile_disc($1::float[]) within group (order by d) as d
		from
      (select started-created as latency, finished-started as d
      from minion_jobs where queue = 'checker' and state = 'finished') j;
    }, \@percentile
  );
  my $r = $result->hash;

  say "Job queue metrics:";
  say "\t$_ => $stats->{$_}" for (qw/enqueued_jobs finished_jobs/);
  say "\tLatency:";
  while (my ($k, $v) = each(@percentile)) {
    say "\t\t@{[$v * 100]}%\t$r->{latency}[$k]";
  }
  say "\tDuration:";
  while (my ($k, $v) = each(@percentile)) {
    say "\t\t@{[$v * 100]}%\t$r->{d}[$k]";
  }

  say "Services status:";
  $result = $db->query(
    q{
    select s.name, r.status, r.count as n, round(100 * count / sum(count) over (partition by s.id), 2) as p
    from
    (select service_id, status, count(*) from runs group by service_id, status) as r
    join services as s on r.service_id = s.id order by s.id, r.status
  }
  );
  say "\tname\tstatus\tn\tp";
  $result->hashes->map(sub { say "\t$_->{name}\t$_->{status}\t$_->{n}\t$_->{p}" });
}

1;
