package CS::Command::watcher;
use Mojo::Base 'Mojolicious::Command';

has description => 'Simple check services';

sub run {
  my $self = shift;
  my $app  = $self->app;

  Mojo::IOLoop->next_tick(sub { $self->check });
  Mojo::IOLoop->recurring(30 => sub { $self->check });

  Mojo::IOLoop->start;
}

sub check {
  my $app = shift->app;
  my $db  = $app->pg->db;

  for my $team (values %{$app->teams}) {
    for my $service (values %{$app->services}) {
      next unless my $port = $service->{tcp_port};
      my $address = $team->{host};
      if (my $cb = $app->config->{cs}{checkers}{hostname}) { $address = $cb->($team, $service) }

      Mojo::IOLoop->client(
        {address => $address, port => $port, timeout => 10} => sub {
          my ($loop, $err, $stream) = @_;
          $db->query(
            'insert into monitor (team_id, service_id, status, round, error)
            values (?, ?, ?, (select max(n) from rounds), ?)', $team->{id}, $service->{id},
            ($err ? 'f' : 't'), $err
          );
          $stream->close if $stream;
        }
      );
    }
  }
}

1;
