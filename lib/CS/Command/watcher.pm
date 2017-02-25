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

  for my $team (values %{$app->teams}) {
    for my $service (values %{$app->services}) {
      next unless my $port = $service->{tcp_port};
      my $address = $team->{host};
      if (my $cb = $app->config->{cs}{checkers}{hostname}) { $address = $cb->($team, $service) }

      Mojo::IOLoop->client(
        {address => $address, port => $port, timeout => 10} => sub {
          my ($loop, $err, $stream) = @_;
          $app->pg->db->insert(
            monitor => {
              team_id    => $team->{id},
              service_id => $service->{id},
              status     => ($err ? 'f' : 't'),
              round      => \'select max(n) from rounds',
              error      => $err
            },
            sub { my ($db, $err) = @_; $app->log->error("[monitor] insert error: $err") if $err }
          );
          $stream->close if $stream;
        }
      );
    }
  }
}

1;
